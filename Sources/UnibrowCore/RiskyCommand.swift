import Foundation

/// A shell command whose effect is hard to judge from its text alone, as
/// recognised in a Bash permission request. Pure: no file or git access.
///
/// Recognition is deliberately narrow. A command that does not match one of
/// these shapes exactly, or whose arguments depend on the shell (variables,
/// globs, command substitution), is not recognised at all.
public enum RiskyCommand: Sendable, Equatable {
    /// `git push --force`, `-f`, `--force-with-lease`, or a `+refspec`.
    case forcePush(ForcePush)
    /// `git reset --hard`, `git checkout [-- ]<paths>`, `git restore <paths>`,
    /// `git clean -f`: uncommitted work is thrown away.
    case discard(Discard)
    /// `rm -r` (any spelling) with its targets.
    case remove(Remove)
    /// A `gh` command that publishes, merges or deletes on GitHub.
    case github(GitHub)

    public struct ForcePush: Sendable, Equatable {
        /// Where git runs.
        public var directory: String
        /// The remote as typed: a name or a URL. `nil`: git's default.
        public var remote: String?
        /// Refspecs as typed, `+` included. Empty: git's default.
        public var refspecs: [String]
        /// `--all` or `--mirror`: every branch.
        public var allBranches: Bool
    }

    public struct Discard: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            /// Tracked changes, staged or not.
            case resetHard(target: String?)
            /// Unstaged changes to the paths; with a source, staged ones too.
            case checkoutPaths(source: String?)
            case restore(source: String?, staged: Bool)
            /// Untracked files; with `-d` in untracked folders too; `-x`
            /// adds ignored files, `-X` removes only those.
            case clean(directories: Bool, ignored: IgnoredFiles)
        }

        public enum IgnoredFiles: Sendable, Equatable { case kept, included, only }

        public var directory: String
        public var kind: Kind
        /// Paths the command is limited to; empty for the whole repository.
        public var pathspecs: [String]
    }

    public struct Remove: Sendable, Equatable {
        /// Absolute targets, lexically joined with the directory `rm` runs in.
        /// `..` is left for the probe, which resolves it like the kernel does.
        public var targets: [String]
    }

    public struct GitHub: Sendable, Equatable {
        public enum Account: Sendable, Equatable {
            /// `GH_TOKEN=$(gh auth token -u <login>)`.
            case login(String)
            /// `GH_TOKEN`/`GITHUB_TOKEN` set to something else.
            case token
            /// No token in the command: whatever `gh` has active.
            case defaultAccount
        }

        /// `pr merge`, `repo delete`, `api DELETE`…
        public var action: String
        public var account: Account
        /// `-R`/`--repo`, `GH_REPO`, or the repository argument.
        public var repository: String?
        /// `gh api`: the endpoint.
        public var endpoint: String?
        /// Where `gh` runs; it finds the repository from there when none is given.
        public var directory: String?
    }

    /// Risky commands in a Bash command line, in order. Empty when there are
    /// none or the line cannot be read reliably.
    ///
    /// - Parameters:
    ///   - cwd: the session's working directory; `cd` in the line moves it.
    ///   - home: expands `~` and `$HOME`.
    public static func recognize(in command: String, cwd: String?, home: String) -> [RiskyCommand] {
        guard let commands = ShellWords.parse(command, home: home) else { return [] }
        var directory = cwd.flatMap { $0.hasPrefix("/") ? $0 : nil }
        var exported: [String: ShellWords.Word] = [:]
        var found: [RiskyCommand] = []

        for command in commands {
            var words = command[...]
            var environment = exported
            // `NAME=value cmd`
            while let first = words.first, let (name, value) = assignment(first) {
                environment[name] = value
                words = words.dropFirst()
            }
            guard let program = unwrap(&words, environment: &environment), program.isLiteral else {
                // An assignment alone is fine. A wrapper with options or a
                // command name that depends on the shell might be a `cd`,
                // so later commands have no known directory.
                if !words.isEmpty { directory = nil }
                continue
            }
            let arguments = Array(words.dropFirst())

            switch program.text {
            case "cd", "pushd":
                directory = changeDirectory(arguments, from: directory, home: home)
            case "export":
                for argument in arguments {
                    if let (name, value) = assignment(argument) { exported[name] = value }
                }
            case "git":
                if let risky = git(arguments, directory: directory) { found.append(risky) }
            case "rm":
                if let risky = remove(arguments, directory: directory) { found.append(.remove(risky)) }
            case "gh":
                if let risky = github(arguments, environment: environment, directory: directory) {
                    found.append(.github(risky))
                }
            default:
                break
            }
        }
        return found
    }

    // MARK: - Shell helpers

    /// `NAME=value` → (NAME, value word). The value keeps its raw text, so a
    /// `$(gh auth token -u me)` can be read later.
    static func assignment(_ word: ShellWords.Word) -> (String, ShellWords.Word)? {
        guard let equals = word.raw.firstIndex(of: "=") else { return nil }
        let name = word.raw[..<equals]
        guard let first = name.first, first.isASCII, first.isLetter || first == "_",
              name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") })
        else { return nil }
        let rawValue = String(word.raw[word.raw.index(after: equals)...])
        let textValue = word.text.firstIndex(of: "=").map { String(word.text[word.text.index(after: $0)...]) } ?? ""
        return (String(name), ShellWords.Word(text: textValue, raw: rawValue, isLiteral: word.isLiteral))
    }

    /// Skips `sudo`, `env`, `command`, `nohup`, `time`, `exec`, `builtin`
    /// in front of the real command. `nil` if a wrapper has options this
    /// reader does not follow.
    static func unwrap(_ words: inout ArraySlice<ShellWords.Word>, environment: inout [String: ShellWords.Word]) -> ShellWords.Word? {
        while let first = words.first {
            guard first.isLiteral else { return first }
            switch first.text {
            case "sudo", "command", "nohup", "time", "exec", "builtin":
                words = words.dropFirst()
                if words.first?.text.hasPrefix("-") == true { return nil }
            case "env":
                words = words.dropFirst()
                while let next = words.first, let (name, value) = assignment(next) {
                    environment[name] = value
                    words = words.dropFirst()
                }
                if words.first?.text.hasPrefix("-") == true { return nil }
            default:
                return first
            }
        }
        return nil
    }

    static func changeDirectory(_ arguments: [ShellWords.Word], from directory: String?, home: String) -> String? {
        let operands = arguments.filter { $0.text != "--" }
        guard operands.count <= 1 else { return nil }
        guard let target = operands.first else { return home.isEmpty ? nil : home }
        guard target.isLiteral, !target.text.hasPrefix("-"), !target.text.isEmpty else { return nil }
        return absolute(target.text, from: directory)
    }

    /// `path` made absolute against `directory`, with `.` and duplicate
    /// slashes removed. `..` stays: only the file system knows where it leads
    /// when a symlink is on the way.
    static func absolute(_ path: String, from directory: String?) -> String? {
        let joined: String
        if path.hasPrefix("/") {
            joined = path
        } else if let directory {
            joined = directory + "/" + path
        } else {
            return nil
        }
        let parts = joined.split(separator: "/", omittingEmptySubsequences: true).filter { $0 != "." }
        return "/" + parts.joined(separator: "/")
    }

    // MARK: - git

    static func git(_ arguments: [ShellWords.Word], directory start: String?) -> RiskyCommand? {
        var directory = start
        var index = 0
        // Global options before the subcommand.
        while index < arguments.count {
            let word = arguments[index]
            guard word.isLiteral else { return nil }
            switch word.text {
            case "-C":
                guard index + 1 < arguments.count, arguments[index + 1].isLiteral else { return nil }
                directory = absolute(arguments[index + 1].text, from: directory)
                index += 2
            case "-c":
                index += 2
            case "--no-pager", "-P", "--no-replace-objects", "--literal-pathspecs", "--no-optional-locks":
                index += 1
            default:
                // `--git-dir`, `--work-tree` and others change which
                // repository is meant; not followed.
                if word.text.hasPrefix("-") { return nil }
                guard let directory else { return nil }
                let rest = Array(arguments[(index + 1)...])
                guard rest.allSatisfy(\.isLiteral) else { return nil }
                let texts = rest.map(\.text)
                switch word.text {
                case "push": return forcePush(texts, directory: directory).map(RiskyCommand.forcePush)
                case "reset": return resetHard(texts, directory: directory).map(RiskyCommand.discard)
                case "checkout": return checkoutPaths(texts, directory: directory).map(RiskyCommand.discard)
                case "restore": return restore(texts, directory: directory).map(RiskyCommand.discard)
                case "clean": return clean(texts, directory: directory).map(RiskyCommand.discard)
                default: return nil
                }
            }
        }
        return nil
    }

    static func forcePush(_ arguments: [String], directory: String) -> ForcePush? {
        var force = false, all = false
        var positional: [String] = []
        var remoteOption: String?
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if argument == "--" {
                positional += arguments[index...]
                break
            }
            if argument == "--force" || argument.hasPrefix("--force-with-lease") {
                force = true
            } else if argument == "--all" || argument == "--mirror" || argument == "--branches" {
                all = true
            } else if argument.hasPrefix("--repo=") {
                remoteOption = String(argument.dropFirst("--repo=".count))
            } else if ["--repo", "--push-option", "--receive-pack", "--exec"].contains(argument) {
                if argument == "--repo", index < arguments.count { remoteOption = arguments[index] }
                index += 1
            } else if argument.hasPrefix("--") {
                continue
            } else if argument.hasPrefix("-"), argument.count > 1 {
                // Bundled short options: `-fu`. `-o` takes a value.
                let letters = argument.dropFirst()
                if letters.contains("f") { force = true }
                if letters.last == "o" { index += 1 }
            } else {
                positional.append(argument)
            }
        }
        let refspecs = Array(positional.dropFirst())
        force = force || refspecs.contains { $0.hasPrefix("+") }
        guard force else { return nil }
        return ForcePush(
            directory: directory,
            remote: positional.first ?? remoteOption,
            refspecs: refspecs,
            allBranches: all
        )
    }

    static func resetHard(_ arguments: [String], directory: String) -> Discard? {
        guard arguments.contains("--hard") else { return nil }
        let operands = arguments.filter { !$0.hasPrefix("-") }
        // `--hard` takes at most a commit, never paths.
        guard operands.count <= 1, !arguments.contains("--") else { return nil }
        return Discard(directory: directory, kind: .resetHard(target: operands.first), pathspecs: [])
    }

    static func checkoutPaths(_ arguments: [String], directory: String) -> Discard? {
        var options: [String] = []
        var operands: [String] = []
        var pathspecs: [String]?
        for (index, argument) in arguments.enumerated() {
            if argument == "--" {
                pathspecs = Array(arguments[(index + 1)...])
                break
            }
            if argument.hasPrefix("-") { options.append(argument) } else { operands.append(argument) }
        }
        // Branch creation, patch mode and merge resolution are something else.
        let allowed: Set<String> = ["-f", "--force", "-q", "--quiet"]
        guard options.allSatisfy(allowed.contains) else { return nil }
        if let pathspecs {
            guard !pathspecs.isEmpty, operands.count <= 1 else { return nil }
            return Discard(directory: directory, kind: .checkoutPaths(source: operands.first), pathspecs: pathspecs)
        }
        // Without `--`, `git checkout main` switches branches; only plain
        // path forms such as `.` and `./src` are read as paths.
        guard !operands.isEmpty, operands.allSatisfy({ $0 == "." || $0.hasPrefix("./") || $0 == ":/" }) else {
            return nil
        }
        return Discard(directory: directory, kind: .checkoutPaths(source: nil), pathspecs: operands)
    }

    static func restore(_ arguments: [String], directory: String) -> Discard? {
        var source: String?
        var staged = false, worktree = false
        var pathspecs: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            switch argument {
            case "--":
                pathspecs += arguments[index...]
                index = arguments.count
            case "-S", "--staged": staged = true
            case "-W", "--worktree": worktree = true
            case "-SW", "-WS": staged = true; worktree = true
            case "-s", "--source":
                guard index < arguments.count else { return nil }
                source = arguments[index]
                index += 1
            case "-q", "--quiet", "--progress", "--no-progress", "--ignore-unmerged", "--overlay", "--no-overlay":
                continue
            default:
                if argument.hasPrefix("--source=") {
                    source = String(argument.dropFirst("--source=".count))
                } else if argument.hasPrefix("-") {
                    // `-p`, `--ours`, `--merge`… are not followed.
                    return nil
                } else {
                    pathspecs.append(argument)
                }
            }
        }
        // `--staged` alone only unstages: the work stays in the files.
        guard !pathspecs.isEmpty, worktree || !staged else { return nil }
        return Discard(directory: directory, kind: .restore(source: source, staged: staged), pathspecs: pathspecs)
    }

    static func clean(_ arguments: [String], directory: String) -> Discard? {
        var force = false, directories = false
        var ignored = Discard.IgnoredFiles.kept
        var pathspecs: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if argument == "--" {
                pathspecs += arguments[index...]
                break
            }
            switch argument {
            case "--force": force = true
            case "--quiet": continue
            case "--dry-run", "--interactive": return nil
            default:
                if argument.hasPrefix("--") {
                    // `--exclude` would make the count wrong.
                    return nil
                } else if argument.hasPrefix("-"), argument.count > 1 {
                    for letter in argument.dropFirst() {
                        switch letter {
                        case "f": force = true
                        case "d": directories = true
                        case "x": ignored = .included
                        case "X": ignored = .only
                        case "q": continue
                        default: return nil // -n, -i, -e
                        }
                    }
                } else {
                    pathspecs.append(argument)
                }
            }
        }
        // Without -f, git refuses (unless clean.requireForce is off).
        guard force else { return nil }
        return Discard(directory: directory, kind: .clean(directories: directories, ignored: ignored), pathspecs: pathspecs)
    }

    // MARK: - rm

    static func remove(_ arguments: [ShellWords.Word], directory: String?) -> Remove? {
        var recursive = false
        var operands: [ShellWords.Word] = []
        var optionsEnded = false
        for argument in arguments {
            if !optionsEnded, argument.isLiteral, argument.text == "--" {
                optionsEnded = true
                continue
            }
            // BSD rm stops reading options at the first operand; GNU rm does
            // not. An option after an operand means different things to
            // each, so the command is not read.
            if !optionsEnded, !operands.isEmpty, argument.text.hasPrefix("-") { return nil }
            if !optionsEnded, operands.isEmpty, argument.text.hasPrefix("-"), argument.text.count > 1 {
                guard argument.isLiteral else { return nil }
                if argument.text.hasPrefix("--") {
                    if argument.text == "--recursive" { recursive = true }
                } else if argument.text.dropFirst().contains(where: { $0 == "r" || $0 == "R" }) {
                    recursive = true
                }
                continue
            }
            operands.append(argument)
        }
        guard recursive, !operands.isEmpty, operands.allSatisfy(\.isLiteral) else { return nil }
        let targets = operands.compactMap { operand -> String? in
            // rm refuses `.` and `..`; keep them visible instead of
            // normalising them into the folder they name.
            let last = operand.text.split(separator: "/").last
            if last == "." || last == ".." {
                if operand.text.hasPrefix("/") { return operand.text }
                return directory.map { $0 + "/" + operand.text }
            }
            return absolute(operand.text, from: directory)
        }
        guard targets.count == operands.count else { return nil }
        return Remove(targets: targets)
    }

    // MARK: - gh

    static func github(_ arguments: [ShellWords.Word], environment: [String: ShellWords.Word], directory: String?) -> GitHub? {
        guard arguments.allSatisfy(\.isLiteral) else { return nil }
        let texts = arguments.map(\.text)
        var repository = environment["GH_REPO"].flatMap { $0.isLiteral ? $0.text : nil }
        var method: String?
        var positional: [String] = []
        var index = 0
        while index < texts.count {
            let argument = texts[index]
            index += 1
            switch argument {
            case "-R", "--repo":
                guard index < texts.count else { return nil }
                repository = texts[index]
                index += 1
            case "-X", "--method":
                guard index < texts.count else { return nil }
                method = texts[index].uppercased()
                index += 1
            default:
                if argument.hasPrefix("--repo=") {
                    repository = String(argument.dropFirst("--repo=".count))
                } else if argument.hasPrefix("--method=") {
                    method = String(argument.dropFirst("--method=".count)).uppercased()
                } else if argument.hasPrefix("-X"), argument.count > 2 {
                    method = String(argument.dropFirst(2)).uppercased()
                } else if argument.hasPrefix("-R"), argument.count > 2 {
                    repository = String(argument.dropFirst(2))
                } else if Self.githubValueOptions.contains(argument) {
                    // Its value is not a positional argument.
                    index += 1
                } else if !argument.hasPrefix("-") {
                    positional.append(argument)
                }
            }
        }
        guard let group = positional.first else { return nil }
        let verb = positional.dropFirst().first
        var endpoint: String?
        let action: String
        switch (group, verb) {
        case ("pr", "create"), ("pr", "merge"), ("release", "create"), ("release", "delete"):
            action = "\(group) \(verb ?? "")"
        case ("repo", "delete"), ("repo", "archive"):
            action = "\(group) \(verb ?? "")"
            // The repository is the argument; without it, the current one.
            if let named = positional.dropFirst(2).first { repository = named }
        case ("api", _) where method == "DELETE":
            action = "api DELETE"
            endpoint = verb
        default:
            return nil
        }
        return GitHub(
            action: action,
            account: account(environment["GH_TOKEN"] ?? environment["GITHUB_TOKEN"]),
            repository: repository,
            endpoint: endpoint,
            directory: directory
        )
    }

    /// `gh` options (of `api`, `pr`, `release`) followed by a separate
    /// value, so the value is not taken for the endpoint or the repository.
    static let githubValueOptions: Set<String> = [
        "-H", "--header", "-f", "-F", "--field", "--raw-field", "--input", "-q", "--jq", "-t", "--template",
        "--hostname", "-p", "--preview", "--cache", "--title", "-b", "--body", "--body-file", "-B", "--base",
        "--head", "-n", "--notes", "--notes-file", "--target", "--milestone", "-l", "--label", "-a", "--assignee",
        "--reviewer", "--project", "--subject", "--match-head-commit", "--author-email",
    ]

    /// Reads the login from `GH_TOKEN=$(gh auth token -u <login>)`, the
    /// pattern that picks one of several `gh` accounts for one command.
    static func account(_ token: ShellWords.Word?) -> GitHub.Account {
        guard let token else { return .defaultAccount }
        var raw = token.raw
        if raw.hasPrefix("\""), raw.hasSuffix("\""), raw.count >= 2 { raw = String(raw.dropFirst().dropLast()) }
        guard raw.hasPrefix("$("), raw.hasSuffix(")") else { return .token }
        let words = raw.dropFirst(2).dropLast().split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard words.count >= 4, words[0] == "gh", words[1] == "auth", words[2] == "token" else { return .token }
        var login: String?
        var index = 3
        while index < words.count {
            let word = words[index]
            if word == "-u" || word == "--user", index + 1 < words.count {
                login = words[index + 1]
                index += 2
            } else if word.hasPrefix("--user=") {
                login = String(word.dropFirst("--user=".count))
                index += 1
            } else if word == "-h" || word == "--hostname" {
                index += 2
            } else {
                return .token
            }
        }
        guard let login, !login.isEmpty,
              login.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
        else { return .token }
        return .login(login)
    }
}
