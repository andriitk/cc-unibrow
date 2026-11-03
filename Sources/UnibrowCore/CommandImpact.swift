public import Foundation

/// A few lines on what a risky command would affect, computed by the relay
/// and shown on the permission card under "Impact".
///
/// Information only: it never changes whether or when Allow is offered, and
/// `ToolSummary.Review` stays the only review rule. Built through `init?`,
/// which escapes and caps every line, so the app shows exactly what it
/// decoded and nothing longer.
public struct ImpactNote: Sendable, Hashable, Codable {
    public let lines: [String]

    public static let maxLines = 3
    public static let maxLineLength = 160

    /// `nil` when no line has any text.
    public init?(lines: [String]) {
        let shown = lines
            .map { ElicitationRequest.display(ToolSummary.firstLine(of: $0), limit: Self.maxLineLength).text }
            .filter { !$0.isEmpty }
            .prefix(Self.maxLines)
        guard !shown.isEmpty else { return nil }
        self.lines = Array(shown)
    }

    private enum CodingKeys: String, CodingKey { case lines }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let lines = try container.decode([String].self, forKey: .lines)
        guard let note = ImpactNote(lines: lines) else {
            throw DecodingError.dataCorruptedError(forKey: .lines, in: container, debugDescription: "No lines")
        }
        self = note
    }
}

/// Turns the risky commands in a Bash permission request into an
/// `ImpactNote`, using read-only lookups within a strict time budget.
public enum CommandImpact {
    /// Total time the relay may spend before it sends the request. Lookups
    /// still running then are stopped and left out.
    public static let budget: Duration = .milliseconds(300)
    /// Counting stops here; the note then says "10,000+".
    public static let maxCount = 10_000

    /// The note for a `PermissionRequest` payload; `nil` unless it is a Bash
    /// command with something risky in it that could be looked up.
    ///
    /// - Parameter projectRoot: the session's repository root; without one,
    ///   its `cwd`. A removal outside it is called out.
    public static func note(
        for payload: HookPayload,
        projectRoot: String?,
        home: String = NSHomeDirectory(),
        probe: ImpactProbe,
        budget: Duration = Self.budget
    ) -> ImpactNote? {
        guard payload.toolName == "Bash", let command = payload.toolInput?["command"]?.stringValue else { return nil }
        let deadline = ContinuousClock.now + budget
        let risky = RiskyCommand.recognize(in: command, cwd: payload.cwd, home: home)
        guard !risky.isEmpty else { return nil }
        let context = Context(probe: probe, deadline: deadline, home: home, projectRoot: projectRoot ?? payload.cwd)
        var lines: [String] = []
        for item in risky {
            guard ContinuousClock.now < deadline else { break }
            lines += context.describe(item)
        }
        return ImpactNote(lines: folded(lines))
    }

    /// At most `ImpactNote.maxLines` lines: the rest become "and N more".
    static func folded(_ lines: [String]) -> [String] {
        guard lines.count > ImpactNote.maxLines else { return lines }
        let kept = lines.prefix(ImpactNote.maxLines - 1)
        return kept + ["… and \(lines.count - kept.count) more"]
    }

    /// Longest path in a line, so a deep path cannot push out what follows.
    static let maxPathLength = 72

    /// `/a/very/long/path` → `/a/ver…ng/path`, keeping more of the end.
    static func shortened(_ text: String, limit: Int) -> String {
        guard text.count > limit, limit > 1 else { return text }
        let head = (limit - 1) / 3
        return "\(text.prefix(head))…\(text.suffix(limit - 1 - head))"
    }

    /// `1234` → `1,234`, the same in every locale.
    static func grouped(_ number: Int) -> String {
        let digits = Array(String(number))
        var result = ""
        for (index, digit) in digits.enumerated() {
            if index > 0, (digits.count - index) % 3 == 0 { result.append(",") }
            result.append(digit)
        }
        return result
    }

    static func counted(_ count: Int, complete: Bool, _ noun: String) -> String {
        let plural = count == 1 && complete ? noun : noun + "s"
        if !complete { return "\(grouped(count))+ \(plural)" }
        return "\(grouped(count)) \(plural)"
    }

    /// Why a removal target deserves attention, most serious first.
    static func removalWarnings(_ path: String, home: String, projectRoot: String?) -> [String] {
        if path == "/" { return ["the whole disk"] }
        var warnings: [String] = []
        let homeFolder = home.count > 1 && home.hasSuffix("/") ? String(home.dropLast()) : home
        if !homeFolder.isEmpty, homeFolder != "/" {
            if path == homeFolder { warnings.append("your home folder") }
            else if homeFolder.hasPrefix(path + "/") { warnings.append("contains your home folder") }
        }
        if warnings.isEmpty, path.split(separator: "/").count == 1 { warnings.append("a top-level folder") }
        if let root = projectRoot, root.hasPrefix("/"), root != "/" {
            if path == root { warnings.append("the whole project") }
            else if root.hasPrefix(path + "/") { if warnings.isEmpty { warnings.append("contains the project") } }
            else if !path.hasPrefix(root + "/") { warnings.append("outside the project") }
        }
        return warnings
    }

    private struct Context {
        let probe: ImpactProbe
        let deadline: ContinuousClock.Instant
        let home: String
        let projectRoot: String?

        /// A path for a line: `~` for home, and a long one shortened in the
        /// middle so the facts after it stay inside the line limit.
        func shown(_ path: String) -> String {
            CommandImpact.shortened(ToolSummary.abbreviatingHome(path, home: home), limit: CommandImpact.maxPathLength)
        }

        /// `git` output, trimmed unless `raw` (status lines start with a space).
        func git(_ arguments: [String], in directory: String, raw: Bool = false) -> String? {
            guard ContinuousClock.now < deadline,
                  let data = probe.git(arguments, directory, deadline)
            else { return nil }
            let output = String(decoding: data, as: UTF8.self)
            return raw ? output : output.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func describe(_ command: RiskyCommand) -> [String] {
            switch command {
            case .forcePush(let push): forcePush(push)
            case .discard(let discard): self.discard(discard)
            case .remove(let remove): remove.targets.map(removal)
            case .github(let github): [self.github(github)]
            }
        }

        // MARK: Force push

        func forcePush(_ push: RiskyCommand.ForcePush) -> [String] {
            let directory = push.directory
            guard probeableConfig(in: directory) != nil else { return [] }
            var remoteName: String?
            var url: String?
            var pushBranch: String?
            if let remote = push.remote {
                // An option-like name is not passed on to git.
                guard !remote.hasPrefix("-") else { return [] }
                if RemoteURL.looksLikeURL(remote) {
                    url = remote
                } else {
                    remoteName = remote
                    url = git(["remote", "get-url", remote], in: directory)
                }
            } else {
                // Where a plain `git push` goes: the push destination of the
                // current branch, e.g. `origin/feature`.
                guard let destination = git(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{push}"], in: directory),
                      let remotes = git(["remote"], in: directory)?.split(separator: "\n").map(String.init),
                      let remote = remotes.filter({ destination.hasPrefix($0 + "/") }).max(by: { $0.count < $1.count })
                else { return [] }
                remoteName = remote
                pushBranch = String(destination.dropFirst(remote.count + 1))
                url = git(["remote", "get-url", remote], in: directory)
            }
            let current = git(["symbolic-ref", "--short", "-q", "HEAD"], in: directory)

            // (local source, remote branch) for each refspec.
            var targets: [(source: String?, branch: String)] = []
            if !push.allBranches {
                if push.refspecs.isEmpty {
                    if let branch = pushBranch ?? current { targets = [(current, branch)] }
                } else {
                    targets = push.refspecs.compactMap { Self.refspec($0, current: current) }
                }
            }

            var destination = remoteName ?? ""
            if let url, let parsed = RemoteURL(url) {
                destination += destination.isEmpty ? parsed.display : " (\(parsed.display))"
            }
            if destination.isEmpty { destination = "remote" }
            let branches: String = if push.allBranches {
                "all branches"
            } else if targets.isEmpty {
                "branch unknown"
            } else if targets.count == 1 {
                "branch \(targets[0].branch)"
            } else {
                "branches " + targets.map(\.branch).joined(separator: ", ")
            }
            var lines = ["Force push to \(destination), \(branches)"]

            // What the remote has that would be overwritten, from local
            // refs only: no fetch, so it is as of the last fetch.
            if targets.count == 1, let remoteName, let source = targets[0].source,
               !source.hasPrefix("-"), !targets[0].branch.hasPrefix("-") {
                let tracking = "\(remoteName)/\(targets[0].branch)"
                if let output = git(["rev-list", "--count", "\(source)..refs/remotes/\(tracking)", "--"], in: directory),
                   let count = Int(output) {
                    let local = source == "HEAD" ? (current ?? "HEAD") : source
                    lines.append(count == 0
                        ? "\(tracking) has no commits missing from \(local) (as of last fetch)"
                        : "\(counted(count, complete: true, "commit")) on \(tracking) not in \(local) would be overwritten (as of last fetch)")
                }
            }
            return lines
        }

        /// `+main:release` → (main, release); `HEAD` → the current branch.
        static func refspec(_ spec: String, current: String?) -> (source: String?, branch: String)? {
            var spec = spec
            if spec.hasPrefix("+") { spec.removeFirst() }
            let parts = spec.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let source = parts[0].isEmpty ? nil : parts[0]
            var branch = parts.count == 2 && !parts[1].isEmpty ? parts[1] : parts[0]
            if branch == "HEAD" || branch == "@" { branch = current ?? "" }
            if branch.hasPrefix("refs/heads/") { branch.removeFirst("refs/heads/".count) }
            guard !branch.isEmpty else { return nil }
            return (source == "@" ? "HEAD" : source, branch)
        }

        // MARK: Discard

        func discard(_ discard: RiskyCommand.Discard) -> [String] {
            // `git status` may hash changed files through a clean filter or
            // a filter process, which are programs. The relay runs before
            // the user approves anything, so no filter may run: not one the
            // repository names, and not a trusted global one either (keys
            // the repository sets, such as `lfs.customtransfer.*`, can steer
            // it). Every driver is switched off for this call; the count may
            // then be approximate for filtered files (LFS).
            guard let config = probeableConfig(in: discard.directory),
                  let filtersOff = config.disablingFilters
            else { return [] }
            // Submodules would be entered with their own config.
            var arguments = filtersOff + ["status", "--porcelain=v1", "-z", "--no-renames", "--ignore-submodules=all"]
            switch discard.kind {
            case .clean(let directories, let ignored):
                arguments.append(directories ? "--untracked-files=all" : "--untracked-files=normal")
                if ignored != .kept { arguments.append("--ignored") }
            default:
                arguments.append("--untracked-files=no")
            }
            arguments += ["--"] + discard.pathspecs
            guard let output = git(arguments, in: discard.directory, raw: true) else { return [] }
            let entries = StatusEntry.parse(output, limit: maxCount)
            let scope = if discard.pathspecs.isEmpty {
                ""
            } else if discard.pathspecs == ["."] {
                " under \(shown(discard.directory))"
            } else {
                " in " + discard.pathspecs.prefix(3).joined(separator: " ")
            }

            switch discard.kind {
            case .resetHard(let target):
                let lost = entries.entries.filter(\.isTracked).count
                var line = lost == 0
                    ? "No uncommitted changes to discard"
                    : "Discards uncommitted changes in \(counted(lost, complete: entries.complete, "file"))"
                if let target { line += "; resets to \(target)" }
                return [line]
            case .checkoutPaths(source: nil), .restore(source: nil, staged: false):
                // Only what is not staged: the index stays.
                let lost = entries.entries.filter { $0.isTracked && $0.worktree != " " }.count
                return [lost == 0
                    ? "No unstaged changes to discard\(scope)"
                    : "Discards unstaged changes in \(counted(lost, complete: entries.complete, "file"))\(scope)"]
            case .checkoutPaths(let source), .restore(let source, _):
                let lost = entries.entries.filter(\.isTracked).count
                let from = source.map { " with \($0)" } ?? ""
                return [lost == 0
                    ? "No uncommitted changes to overwrite\(scope)"
                    : "Overwrites uncommitted changes in \(counted(lost, complete: entries.complete, "file"))\(scope)\(from)"]
            case .clean(let directories, let ignored):
                let deleted = entries.entries.filter { entry in
                    let kind = entry.isUntracked && ignored != .only || entry.isIgnored && ignored != .kept
                    // Without -d, git clean leaves untracked folders alone.
                    return kind && (directories || !entry.path.hasSuffix("/"))
                }.count
                let noun = ignored == .only ? "ignored item" : ignored == .included ? "untracked or ignored item" : "untracked item"
                return [deleted == 0
                    ? "Nothing to delete\(scope)"
                    : "Deletes \(counted(deleted, complete: entries.complete, noun))\(scope)"]
            }
        }

        /// The repository's git config, when git may be asked anything
        /// there at all: `nil` if it cannot be read or the repository is a
        /// partial clone, where `status` or `rev-list` could fetch missing
        /// objects over the network (`GIT_NO_LAZY_FETCH` stops that only
        /// from git 2.44). Reading config runs nothing. `--list` rather than
        /// `--get-regexp`, which exits 1 when nothing matches and so looks
        /// like a failure here.
        func probeableConfig(in directory: String) -> RepositoryGitConfig? {
            guard let listing = git(["config", "--list", "--show-scope", "--includes", "-z"], in: directory, raw: true),
                  let config = RepositoryGitConfig(listing: listing),
                  !config.isPartialClone
            else { return nil }
            return config
        }

        // MARK: Removal

        func removal(_ target: String) -> String {
            let parts = target.split(separator: "/")
            if parts.last == "." || parts.last == ".." {
                return "\(shown(target)): rm refuses . and .."
            }
            // Compare and look up where the kernel goes: the parent folder
            // resolved (`a/link/../b`, `/tmp` → `/private/tmp`), the last
            // part kept as is, since rm removes a link, not its target.
            var path = target
            var displayed = target
            if target != "/" {
                let parent = (target as NSString).deletingLastPathComponent
                if let real = probe.realPath(parent) {
                    path = (real == "/" ? "" : real) + "/" + (target as NSString).lastPathComponent
                } else if parts.contains("..") {
                    return "\(shown(target)): not found"
                }
                // A `..` reads better resolved; otherwise show what was typed.
                if parts.contains("..") { displayed = path }
            }
            var facts: [String]
            switch probe.entry(path) {
            case nil:
                facts = ["not found"]
            case .symlink?:
                facts = ["symlink, only the link is removed"]
            case .file?:
                facts = ["file"]
            case .other?:
                facts = ["special file"]
            case .directory?:
                let result = probe.countItems(path, maxCount, deadline)
                facts = ["folder, \(counted(result.count, complete: result.complete, "item"))"]
            }
            facts += removalWarnings(
                path,
                home: probe.realPath(home) ?? home,
                projectRoot: projectRoot.map { probe.realPath($0) ?? $0 }
            )
            return "\(shown(displayed)): " + facts.joined(separator: ", ")
        }

        // MARK: GitHub

        func github(_ github: RiskyCommand.GitHub) -> String {
            let account = switch github.account {
            case .login(let login): login
            case .token: "the account in GH_TOKEN"
            case .defaultAccount: "gh default account"
            }
            let target: String
            if let endpoint = github.endpoint {
                target = endpoint
            } else if let repository = github.repository {
                target = repository
            } else if let directory = github.directory,
                      probeableConfig(in: directory) != nil,
                      let url = git(["remote", "get-url", "origin"], in: directory),
                      let parsed = RemoteURL(url) {
                target = "\(parsed.path) (origin)"
            } else {
                target = "repository unknown"
            }
            return "gh \(github.action) as \(account) → \(target)"
        }
    }
}

/// What the impact probe needs to know from `git config --list
/// --show-scope --includes -z` before it runs anything else in a repository.
struct RepositoryGitConfig: Equatable {
    /// Filter drivers with a `clean`, `smudge` or `process` command in any
    /// scope, in order of appearance.
    var filterDrivers: [String] = []
    /// `extensions.partialClone` or a `remote.<name>.promisor` that is not
    /// false: objects may be missing locally and fetched on demand.
    var isPartialClone = false

    /// More drivers than this and `git status` is not run at all.
    static let maxFilterDrivers = 50

    /// `nil` when the listing is not in the expected shape.
    init?(listing: String) {
        // `-z`: `scope<NUL>key<LF>value<NUL>` for each entry.
        let fields = listing.split(separator: "\0", omittingEmptySubsequences: false)
        guard fields.count % 2 == 1, fields.last?.isEmpty == true else { return nil }
        for index in stride(from: 1, to: fields.count - 1, by: 2) {
            let entry = fields[index]
            let key = String(entry.prefix { $0 != "\n" })
            let value = entry.drop { $0 != "\n" }.dropFirst().lowercased()
            // Section and variable names are case-insensitive (git prints
            // them lowercased); a subsection (the driver name) is not.
            let lowered = key.lowercased()
            if lowered == "extensions.partialclone" {
                isPartialClone = true
            } else if lowered.hasPrefix("remote."), lowered.hasSuffix(".promisor"),
                      !["false", "no", "off", "0"].contains(value) {
                isPartialClone = true
            } else if lowered.hasPrefix("filter."), let dot = key.lastIndex(of: "."),
                      ["clean", "smudge", "process"].contains(lowered[lowered.index(after: dot)...]) {
                let name = String(key[key.index(key.startIndex, offsetBy: "filter.".count)..<dot])
                if !filterDrivers.contains(name) { filterDrivers.append(name) }
            }
        }
    }

    /// `-c` options that switch every filter driver off for one git call
    /// (an empty command means "no filter"; `required=false` keeps git from
    /// failing for lack of one). `nil` if a name cannot be passed safely.
    var disablingFilters: [String]? {
        guard filterDrivers.count <= Self.maxFilterDrivers else { return nil }
        var options: [String] = []
        for name in filterDrivers {
            guard !name.isEmpty, !name.contains("="), !name.contains(where: \.isNewline) else { return nil }
            for setting in ["clean=", "smudge=", "process=", "required=false"] {
                options += ["-c", "filter.\(name).\(setting)"]
            }
        }
        return options
    }
}

/// One line of `git status --porcelain=v1 -z`.
struct StatusEntry: Equatable {
    var index: Character
    var worktree: Character
    var path: String

    var isUntracked: Bool { index == "?" }
    var isIgnored: Bool { index == "!" }
    var isTracked: Bool { !isUntracked && !isIgnored }

    /// Entries in `output`, at most `limit`; `complete` is false when cut.
    static func parse(_ output: String, limit: Int) -> (entries: [StatusEntry], complete: Bool) {
        var entries: [StatusEntry] = []
        for record in output.split(separator: "\0", omittingEmptySubsequences: true) {
            let characters = Array(record.prefix(3))
            guard characters.count == 3, characters[2] == " " else { continue }
            if entries.count == limit { return (entries, false) }
            entries.append(StatusEntry(index: characters[0], worktree: characters[1], path: String(record.dropFirst(3))))
        }
        return (entries, true)
    }
}

/// A git remote URL reduced to what identifies the repository: the host (an
/// SSH alias such as `github.com-work` included) and the path. User names and
/// passwords in the URL are never kept.
public struct RemoteURL: Sendable, Equatable {
    public let host: String?
    public let path: String

    public init?(_ url: String) {
        let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return nil }
        if let scheme = url.range(of: "://") {
            let rest = url[scheme.upperBound...]
            let slash = rest.firstIndex(of: "/") ?? rest.endIndex
            var authority = rest[..<slash]
            if let at = authority.lastIndex(of: "@") { authority = authority[authority.index(after: at)...] }
            if let colon = authority.lastIndex(of: ":"), authority[authority.index(after: colon)...].allSatisfy(\.isNumber) {
                authority = authority[..<colon]
            }
            host = authority.isEmpty ? nil : String(authority)
            path = Self.trimmed(String(rest[slash...]))
        } else if !url.hasPrefix("/"), !url.hasPrefix("."), !url.hasPrefix("~"),
                  let colon = url.firstIndex(of: ":"), !url[..<colon].contains("/") {
            // scp-like: `[user@]host:owner/repo.git`
            var authority = url[..<colon]
            if let at = authority.lastIndex(of: "@") { authority = authority[authority.index(after: at)...] }
            host = authority.isEmpty ? nil : String(authority)
            path = Self.trimmed(String(url[url.index(after: colon)...]))
        } else {
            host = nil
            path = url
        }
        guard !path.isEmpty else { return nil }
    }

    /// `github.com-work → org/app`, or the path alone for a local remote.
    public var display: String {
        host.map { "\($0) → \(path)" } ?? path
    }

    /// A remote given as a URL or path rather than a remote name.
    static func looksLikeURL(_ text: String) -> Bool {
        text.contains("://") || text.contains(":") || text.hasPrefix("/") || text.hasPrefix(".") || text.hasPrefix("~")
    }

    private static func trimmed(_ path: String) -> String {
        var path = path
        while path.hasPrefix("/") { path.removeFirst() }
        while path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix(".git") { path.removeLast(4) }
        return path
    }
}
