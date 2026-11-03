import Foundation
import Testing
@testable import UnibrowCore

@Suite("Risky command recognition")
struct RiskyCommandTests {
    private static let home = "/Users/me"
    private static let cwd = "/Users/me/code/shop"

    private static func recognize(_ command: String, cwd: String? = cwd) -> [RiskyCommand] {
        RiskyCommand.recognize(in: command, cwd: cwd, home: home)
    }

    private static func push(_ command: String) -> RiskyCommand.ForcePush? {
        guard case .forcePush(let push)? = recognize(command).first else { return nil }
        return push
    }

    private static func targets(_ command: String, cwd: String? = cwd) -> [String]? {
        guard case .remove(let remove)? = recognize(command, cwd: cwd).first else { return nil }
        return remove.targets
    }

    // MARK: Shell reading

    @Test("Words: quotes, escapes, home and redirections")
    func words() throws {
        let commands = try #require(ShellWords.parse(#"git commit -m "a b" 'c d' e\ f ~/x "$HOME"/y 2>/dev/null > out.txt"#, home: Self.home))
        #expect(commands.count == 1)
        #expect(commands[0].words.map(\.text) == ["git", "commit", "-m", "a b", "c d", "e f", "/Users/me/x", "/Users/me/y"])
        #expect(commands[0].words.allSatisfy { $0.isLiteral })
        #expect(commands[0].separator == .end)
    }

    @Test("Chains split into commands, each with the operator after it", arguments: [
        ("a && b", ShellWords.Command.Separator.and), ("a; b", .sequence), ("a || b", .or), ("a | b", .pipe),
        ("a & b", .background), ("a\nb", .sequence), ("a |& b", .pipe), ("a &&\nb", .and),
    ])
    func chains(line: String, separator: ShellWords.Command.Separator) throws {
        let commands = try #require(ShellWords.parse(line, home: Self.home))
        #expect(commands.map { $0.words.map(\.text) } == [["a"], ["b"]])
        #expect(commands.map(\.separator) == [separator, .end])
    }

    @Test("Words the shell would change are not literal", arguments: [
        "rm $DIR", "rm \"$DIR\"", "rm *.log", "rm a?", "rm {a,b}", "rm $(pwd)", "rm `pwd`", "rm ~bob", "rm $'a\\nb'", "rm $1",
    ])
    func nonLiteral(line: String) throws {
        let commands = try #require(ShellWords.parse(line, home: Self.home))
        #expect(commands[0].words.last?.isLiteral == false)
    }

    @Test("Constructs the reader does not follow make it give up", arguments: [
        "(cd /tmp && rm -rf x)", "cat <<EOF\nrm -rf /\nEOF", "cat <<< 'rm -rf /'", "diff <(ls) <(ls a)",
        "if true; then rm -rf x; fi", "for f in a; do rm -rf $f; done", "{ rm -rf x; }", "echo 'unterminated",
        "f() { rm -rf x; }",
    ])
    func unreadable(line: String) {
        #expect(ShellWords.parse(line, home: Self.home) == nil)
        #expect(Self.recognize(line).isEmpty)
    }

    @Test("Text that merely mentions a risky command is not one", arguments: [
        "echo git push --force", "git log --grep='push -f'", "grep -r 'rm -rf' .", "# rm -rf /",
        "git commit -m 'git push -f later'", "printf '%s' \"rm -rf ~\"",
    ])
    func mentions(line: String) {
        #expect(Self.recognize(line).isEmpty)
    }

    // MARK: git push

    @Test("Force push spellings", arguments: [
        "git push --force", "git push -f origin main", "git push origin main --force",
        "git push --force-with-lease", "git push --force-with-lease=main:abc origin main",
        "git push origin +main", "git push -uf origin main", "git -C sub push -f",
        "cd sub && git push -f", "GIT_SSH_COMMAND='ssh -v' git push -f", "sudo git push -f",
    ])
    func forcePushSpellings(line: String) {
        #expect(Self.push(line) != nil)
    }

    @Test("Ordinary pushes are not flagged", arguments: [
        "git push", "git push origin main", "git push --force-if-includes", "git push --no-force-with-lease",
        "git push -u origin feature", "git pull --force",
    ])
    func ordinaryPush(line: String) {
        #expect(Self.push(line) == nil)
    }

    @Test("Remote, refspecs and directory are read")
    func pushDetails() throws {
        let push = try #require(Self.push("cd sub && git push -o ci.skip -f upstream +HEAD:release main"))
        #expect(push.directory == "/Users/me/code/shop/sub")
        #expect(push.remote == "upstream")
        #expect(push.refspecs == ["+HEAD:release", "main"])
        #expect(!push.allBranches)

        let all = try #require(Self.push("git push --mirror --force origin"))
        #expect(all.allBranches && all.remote == "origin" && all.refspecs.isEmpty)

        let option = try #require(Self.push("git push --repo=backup -f"))
        #expect(option.remote == "backup")

        let absolute = try #require(Self.push("git -C /srv/app push -f"))
        #expect(absolute.directory == "/srv/app")
    }

    @Test("cd moves later commands only where bash certainly would", arguments: [
        // Followed by &&: what follows runs in the new folder or not at all.
        ("cd sub && rm -rf build", ["/Users/me/code/shop/sub/build"]),
        ("cd sub && cd deeper && rm -rf build", ["/Users/me/code/shop/sub/deeper/build"]),
        ("cd sub && ls | rm -rf build", ["/Users/me/code/shop/sub/build"]),
        // cd may have failed, and rm runs anyway in the old folder.
        ("cd /missing; rm -rf build", nil),
        ("cd /missing\nrm -rf build", nil),
        ("cd sub || rm -rf build", nil),
        // A pipeline element or a background job runs in a subshell.
        ("cd sub | rm -rf build", nil),
        ("ls | cd sub && rm -rf build", nil),
        ("cd sub & rm -rf build", nil),
        // An || before the cd may have skipped it.
        ("false || cd sub && rm -rf build", nil),
        // The directory stack is not followed.
        ("pushd sub && popd && rm -rf build", nil),
        ("pushd && rm -rf build", nil),
        // Absolute targets do not depend on the folder.
        ("cd /missing; rm -rf /tmp/x", ["/tmp/x"]),
    ] as [(String, [String]?)])
    func directoryAcrossSeparators(line: String, expected: [String]?) {
        #expect(Self.targets(line) == expected)
    }

    @Test("A cd behind a wrapper that runs an external program does not move the shell", arguments: [
        "env cd /x && rm -rf build", "sudo cd /x && rm -rf build", "nohup cd /x && rm -rf build",
        "exec cd /x && rm -rf build", "time cd /x && rm -rf build", "env FOO=1 cd /x && rm -rf build",
        "env pushd /x && rm -rf build", "sudo popd && rm -rf build",
    ])
    func wrappedCD(line: String) {
        #expect(Self.targets(line) == nil)
    }

    @Test("A cd that the shell itself runs still moves it", arguments: [
        "command cd /x && rm -rf build", "builtin cd /x && rm -rf build", "FOO=1 cd /x && rm -rf build",
    ])
    func builtinCD(line: String) {
        #expect(Self.targets(line) == ["/x/build"])
    }

    @Test("An export behind env or sudo is not followed")
    func wrappedExport() {
        #expect(Self.recognize("env export GH_TOKEN=$(gh auth token -u me); gh pr merge").isEmpty)
    }

    @Test("After the && chain of a cd ends, the folder is unknown")
    func directoryAfterChain() {
        // bash: `rm -rf a` runs only if `cd sub` worked, so in sub. `rm -rf b`
        // runs either way: in sub if cd worked, in the old folder if not.
        // Which one is not known in advance, so b gets no target.
        let found = Self.recognize("cd sub && rm -rf a; rm -rf b")
        #expect(found == [.remove(.init(targets: ["/Users/me/code/shop/sub/a"]))])
        // Without a cd, a ; keeps the session folder.
        #expect(Self.recognize("rm -rf a; rm -rf b").count == 2)
        #expect(Self.recognize("cd sub && rm -rf a || rm -rf b").count == 1)
    }

    @Test("gh is skipped when the token may or may not have been exported")
    func uncertainExports() {
        let login = "export GH_TOKEN=$(gh auth token -u me)"
        guard case .github(let github)? = Self.recognize("\(login); gh pr merge").first else {
            Issue.record("unconditional export not followed")
            return
        }
        #expect(github.account == .login("me"))
        #expect(Self.recognize("test -n x && \(login); gh pr merge").isEmpty)
        #expect(Self.recognize("\(login) & gh pr merge").isEmpty)
        #expect(Self.recognize("GH_TOKEN=$(gh auth token -u me); gh pr merge").isEmpty)
        #expect(Self.recognize("\(login); unset GH_TOKEN; gh pr merge").isEmpty)
    }

    @Test("A push whose directory is unknown is skipped")
    func pushUnknownDirectory() {
        #expect(Self.recognize("git push -f", cwd: nil).isEmpty)
        #expect(Self.recognize("cd $DIR && git push -f").isEmpty)
        #expect(Self.recognize("cd - && git push -f").isEmpty)
        #expect(Self.recognize("git --git-dir=x push -f").isEmpty)
        #expect(Self.recognize("git push -f $REMOTE").isEmpty)
    }

    // MARK: Discarding work

    @Test("Commands that discard work", arguments: [
        ("git reset --hard", RiskyCommand.Discard.Kind.resetHard(target: nil), [String]()),
        ("git reset --hard HEAD~2", .resetHard(target: "HEAD~2"), []),
        ("git checkout -- .", .checkoutPaths(source: nil), ["."]),
        ("git checkout .", .checkoutPaths(source: nil), ["."]),
        ("git checkout main -- src", .checkoutPaths(source: "main"), ["src"]),
        ("git restore .", .restore(source: nil, staged: false), ["."]),
        ("git restore --source=HEAD~1 -SW a b", .restore(source: "HEAD~1", staged: true), ["a", "b"]),
        ("git clean -fd", .clean(directories: true, ignored: .kept), []),
        ("git clean -f -x src", .clean(directories: false, ignored: .included), ["src"]),
        ("git clean -fX", .clean(directories: false, ignored: .only), []),
    ])
    func discards(line: String, kind: RiskyCommand.Discard.Kind, pathspecs: [String]) throws {
        guard case .discard(let discard)? = Self.recognize(line).first else {
            Issue.record("\(line) not recognised")
            return
        }
        #expect(discard.kind == kind)
        #expect(discard.pathspecs == pathspecs)
        #expect(discard.directory == Self.cwd)
    }

    @Test("Similar commands that keep work are not flagged", arguments: [
        "git reset", "git reset --soft HEAD~1", "git reset HEAD file", "git checkout main", "git checkout -b x",
        "git checkout -p .", "git restore --staged .", "git restore -p .", "git clean -n", "git clean -nd",
        "git clean -d", "git clean -fi", "git clean -f -e '*.log'", "git restore",
    ])
    func keepsWork(line: String) {
        #expect(Self.recognize(line).isEmpty)
    }

    // MARK: rm

    @Test("rm -r spellings resolve their targets", arguments: [
        ("rm -rf build", ["/Users/me/code/shop/build"]),
        ("rm -fr ./build/ dist", ["/Users/me/code/shop/build", "/Users/me/code/shop/dist"]),
        ("rm -R -f -- -weird", ["/Users/me/code/shop/-weird"]),
        ("rm --recursive x", ["/Users/me/code/shop/x"]),
        ("rm -rf /", ["/"]),
        ("rm -rf ~", ["/Users/me"]),
        ("rm -rf \"$HOME\"", ["/Users/me"]),
        ("rm -rf ${HOME}/Library", ["/Users/me/Library"]),
        ("rm -rf '/tmp/a b'", ["/tmp/a b"]),
        ("cd /tmp && rm -rf ../etc", ["/tmp/../etc"]),
        ("sudo rm -rf /opt/x", ["/opt/x"]),
    ])
    func removals(line: String, expected: [String]) {
        #expect(Self.targets(line) == expected)
    }

    @Test("rm without -r, with shell-dependent targets, or with options after operands is skipped", arguments: [
        "rm file.txt", "rm -f a", "rm -rf $DIR", "rm -rf *", "rm -rf build/*", "rm -rf \"$TMP/x\"", "rm -rf `pwd`",
        "rm build -rf", "rm -rf", "xargs rm -rf", "find . -delete", "sudo -u bob rm -rf x",
    ])
    func removalSkipped(line: String) {
        #expect(Self.targets(line) == nil)
    }

    @Test("A relative target needs a known directory")
    func relativeTargetWithoutDirectory() {
        #expect(Self.targets("rm -rf build", cwd: nil) == nil)
        #expect(Self.targets("rm -rf /abs", cwd: nil) == ["/abs"])
    }

    // MARK: gh

    @Test("gh commands, account and repository", arguments: [
        ("gh pr create --fill", "pr create", RiskyCommand.GitHub.Account.defaultAccount, nil as String?),
        ("GH_TOKEN=$(gh auth token -u andrii-tkachuk-mint) gh pr merge 12 --squash", "pr merge", .login("andrii-tkachuk-mint"), nil),
        ("GH_TOKEN=\"$(gh auth token --user work)\" gh repo delete org/app --yes", "repo delete", .login("work"), "org/app"),
        ("GH_TOKEN=abc gh release create v1 -R org/app", "release create", .token, "org/app"),
        ("export GH_TOKEN=$(gh auth token -u me); gh repo archive", "repo archive", .login("me"), nil),
        ("gh release delete v1 --repo=org/x", "release delete", .defaultAccount, "org/x"),
        ("GITHUB_TOKEN=$(cat t) gh pr merge", "pr merge", .token, nil),
        ("GH_TOKEN=$(gh auth token -u me; rm -rf x) gh pr merge", "pr merge", .token, nil),
    ])
    func github(line: String, action: String, account: RiskyCommand.GitHub.Account, repository: String?) throws {
        guard case .github(let github)? = Self.recognize(line).first else {
            Issue.record("\(line) not recognised")
            return
        }
        #expect(github.action == action)
        #expect(github.account == account)
        #expect(github.repository == repository)
        #expect(github.directory == Self.cwd)
    }

    @Test("gh api DELETE and its endpoint")
    func githubAPI() throws {
        for line in ["gh api -X DELETE repos/o/r/git/refs/heads/x", "gh api --method delete repos/o/r/git/refs/heads/x", "gh api -XDELETE repos/o/r/git/refs/heads/x"] {
            guard case .github(let github)? = Self.recognize(line).first else {
                Issue.record("\(line) not recognised")
                continue
            }
            #expect(github.action == "api DELETE")
            #expect(github.endpoint == "repos/o/r/git/refs/heads/x")
        }
    }

    @Test("Read-only gh commands are not flagged", arguments: [
        "gh pr view 1", "gh pr list", "gh api repos/o/r", "gh api -X GET repos/o/r", "gh repo view", "gh release list",
    ])
    func githubReadOnly(line: String) {
        #expect(Self.recognize(line).isEmpty)
    }

    @Test("Several risky commands in one line are all found")
    func severalInOneLine() {
        let found = Self.recognize("rm -rf dist && git reset --hard && git push -f")
        #expect(found.count == 3)
    }
}
