import Foundation
import Testing
@testable import UnibrowCore

/// A throwaway directory with real paths (`/private/var/…`, not the
/// `/var/…` symlink), removed at the end of the test.
private final class TempDirectory {
    let path: String

    init() throws {
        // Short, so lines with these paths stay under the line limit.
        let base = URL(filePath: "/tmp/unibrow-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        guard let real = realpath(base.path, nil) else { throw CocoaError(.fileNoSuchFile) }
        defer { free(real) }
        path = String(cString: real)
    }

    deinit { try? FileManager.default.removeItem(atPath: path) }

    func file(_ relative: String, _ contents: String = "x") throws {
        let url = URL(filePath: path).appending(path: relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    @discardableResult
    func git(_ arguments: String..., in directory: String? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = URL(filePath: directory ?? path)
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_AUTHOR_NAME"] = "t"; environment["GIT_AUTHOR_EMAIL"] = "t@example.com"
        environment["GIT_COMMITTER_NAME"] = "t"; environment["GIT_COMMITTER_EMAIL"] = "t@example.com"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.executableLoad, userInfo: [NSLocalizedDescriptionKey: "git \(arguments) failed"])
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// A repository at `name` with one commit on `main`.
    func repository(_ name: String = "work") throws -> String {
        let root = path + "/" + name
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try git("init", "-q", "-b", "main", in: root)
        try file(name + "/README.md", "hello")
        try git("add", ".", in: root)
        try git("commit", "-q", "-m", "first", in: root)
        return root
    }
}

@Suite("Command impact")
struct CommandImpactTests {
    private static let home = "/Users/me"

    private static func payload(_ command: String, cwd: String, tool: String = "Bash") -> HookPayload {
        HookPayload(raw: .object([
            "session_id": .string("s1"),
            "cwd": .string(cwd),
            "tool_name": .string(tool),
            "tool_input": .object(["command": .string(command)]),
        ]))
    }

    private static func note(
        _ command: String,
        cwd: String,
        projectRoot: String? = nil,
        home: String = home,
        probe: ImpactProbe = .live(),
        budget: Duration = CommandImpact.budget
    ) -> [String]? {
        CommandImpact.note(
            for: payload(command, cwd: cwd), projectRoot: projectRoot, home: home, probe: probe, budget: budget
        )?.lines
    }

    /// Answers git calls from a table; no file system.
    private static func fake(
        git answers: [String: String] = [:],
        entries: [String: ImpactProbe.Entry] = [:],
        count: (Int, Bool) = (3, true)
    ) -> ImpactProbe {
        ImpactProbe(
            git: { arguments, _, _ in answers[arguments.joined(separator: " ")].map { Data($0.utf8) } },
            entry: { entries[$0] },
            countItems: { _, _, _ in count },
            realPath: { $0 }
        )
    }

    // MARK: The note itself

    @Test("Only risky Bash commands get a note")
    func onlyRiskyBash() {
        let probe = Self.fake(entries: ["/p/build": .directory])
        #expect(Self.note("ls -la", cwd: "/p", probe: probe) == nil)
        #expect(Self.note("rm -rf build", cwd: "/p", probe: probe) != nil)
        let write = CommandImpact.note(for: Self.payload("rm -rf build", cwd: "/p", tool: "Write"), projectRoot: nil, home: Self.home, probe: probe)
        #expect(write == nil)
    }

    @Test("Lines are escaped and capped; more than three fold into a count")
    func noteShape() throws {
        let note = try #require(ImpactNote(lines: ["a\u{202E}b", String(repeating: "x", count: 500), "", "d", "e"]))
        #expect(note.lines.count == 3)
        #expect(note.lines[0] == "a\\u{202E}b")
        #expect(note.lines[1].count == ImpactNote.maxLineLength + 1)
        #expect(ImpactNote(lines: ["", "  "]) == nil)

        #expect(CommandImpact.folded(["1", "2", "3", "4", "5"]) == ["1", "2", "… and 3 more"])
        #expect(CommandImpact.folded(["1", "2", "3"]) == ["1", "2", "3"])
        #expect(CommandImpact.grouped(1_234_567) == "1,234,567")
        #expect(CommandImpact.grouped(999) == "999")
    }

    @Test("Removal warnings", arguments: [
        ("/", ["the whole disk"]),
        ("/Users/me", ["your home folder"]),
        ("/Users", ["contains your home folder"]),
        ("/etc", ["a top-level folder", "outside the project"]),
        ("/Users/me/code/shop", ["the whole project"]),
        ("/Users/me/code", ["contains the project"]),
        ("/Users/me/code/shop/build", [String]()),
        ("/Users/me/code/shopping", ["outside the project"]),
    ])
    func removalWarnings(path: String, expected: [String]) {
        #expect(CommandImpact.removalWarnings(path, home: Self.home, projectRoot: "/Users/me/code/shop") == expected)
    }

    @Test("Remote URLs reduce to host and path, without credentials", arguments: [
        ("git@github.com-mint:mint-ai/app.git", "github.com-mint", "mint-ai/app"),
        ("https://user:s3cret@github.com/org/repo.git", "github.com", "org/repo"),
        ("ssh://git@example.com:2222/team/proj.git/", "example.com", "team/proj"),
        ("/srv/git/app.git", nil, "/srv/git/app.git"),
    ] as [(String, String?, String)])
    func remoteURLs(url: String, host: String?, path: String) throws {
        let parsed = try #require(RemoteURL(url))
        #expect(parsed.host == host)
        #expect(parsed.path == path)
        #expect(!parsed.display.contains("s3cret"))
    }

    @Test("gh: account and repository from -R or the origin remote")
    func githubLines() {
        let probe = Self.fake(git: ["remote get-url origin": "git@github.com-mint:mint-ai/app.git\n"])
        #expect(Self.note("GH_TOKEN=$(gh auth token -u andrii-tkachuk-mint) gh pr merge 3", cwd: "/p", probe: probe)
            == ["gh pr merge as andrii-tkachuk-mint → mint-ai/app (origin)"])
        #expect(Self.note("gh repo delete org/old --yes", cwd: "/p", probe: probe)
            == ["gh repo delete as gh default account → org/old"])
        #expect(Self.note("GH_TOKEN=x gh api -X DELETE repos/o/r/git/refs/heads/f", cwd: "/p", probe: probe)
            == ["gh api DELETE as the account in GH_TOKEN → repos/o/r/git/refs/heads/f"])
        #expect(Self.note("gh pr create", cwd: "/p", probe: Self.fake())
            == ["gh pr create as gh default account → repository unknown"])
    }

    @Test("A count that hit the cap says so")
    func countCap() {
        let probe = Self.fake(entries: ["/p/node_modules": .directory], count: (CommandImpact.maxCount, false))
        #expect(Self.note("rm -rf node_modules", cwd: "/p", projectRoot: "/p", probe: probe)
            == ["/p/node_modules: folder, 10,000+ items"])
    }

    @Test("A long path is shortened in the middle, so its facts stay in the line")
    func longPath() {
        let deep = "/p/" + Array(repeating: "a-rather-long-folder-name", count: 10).joined(separator: "/")
        let probe = Self.fake(entries: [deep: .directory])
        let line = Self.note("rm -rf \(deep)", cwd: "/p", projectRoot: "/q", probe: probe)?.first ?? ""
        #expect(line.hasSuffix("folder, 3 items, outside the project"))
        #expect(line.contains("…"))
        #expect(line.count <= ImpactNote.maxLineLength)
    }

    // MARK: Live probes: git

    @Test("Force push: remote host and repo, branch, and commits only the remote has")
    func forcePushLive() throws {
        let temp = try TempDirectory()
        try temp.git("init", "-q", "--bare", "-b", "main", "remote.git")
        let work = try temp.repository()
        try temp.git("remote", "add", "origin", temp.path + "/remote.git", in: work)
        try temp.git("push", "-q", "-u", "origin", "main", in: work)
        // Someone else pushes two commits; we fetch them.
        try temp.git("clone", "-q", temp.path + "/remote.git", "other")
        let other = temp.path + "/other"
        for name in ["a", "b"] {
            try temp.file("other/\(name).txt")
            try temp.git("add", ".", in: other)
            try temp.git("commit", "-q", "-m", name, in: other)
        }
        try temp.git("push", "-q", "origin", "main", in: other)
        try temp.git("fetch", "-q", "origin", in: work)
        // Only the URL changes; refs stay local, nothing is fetched.
        try temp.git("remote", "set-url", "origin", "git@github.com-mint:mint-ai/app.git", in: work)

        #expect(Self.note("git push --force", cwd: work) == [
            "Force push to origin (github.com-mint → mint-ai/app), branch main",
            "2 commits on origin/main not in main would be overwritten (as of last fetch)",
        ])
        #expect(Self.note("cd .. && cd work && git push -f origin +HEAD:main", cwd: work)?.last
            == "2 commits on origin/main not in main would be overwritten (as of last fetch)")
        // No tracking ref for that branch: no count, and nothing made up.
        #expect(Self.note("git push origin +main:release", cwd: work) == [
            "Force push to origin (github.com-mint → mint-ai/app), branch release",
        ])
        // In sync: says so.
        try temp.git("reset", "-q", "--hard", "origin/main", in: work)
        #expect(Self.note("git push -f origin main", cwd: work)?.last
            == "origin/main has no commits missing from main (as of last fetch)")
        // An unknown remote: just the name.
        #expect(Self.note("git push -f nowhere main", cwd: work) == ["Force push to nowhere, branch main"])
    }

    /// A repository whose `.gitattributes` sends every file through the
    /// `evil` clean filter, and a tracked file changed since the commit, so
    /// `git status` would have to run the filter to compare it.
    private static func filteredRepository(_ temp: TempDirectory) throws -> (work: String, marker: String) {
        let work = try temp.repository()
        try temp.file("work/tracked.txt", "one")
        try temp.git("add", ".", in: work)
        try temp.git("commit", "-q", "-m", "tracked", in: work)
        try temp.file("work/.gitattributes", "* filter=evil\n")
        try temp.file("work/tracked.txt", "two")
        let marker = temp.path + "/filter-ran"
        try temp.file("filter.sh", "#!/bin/sh\ntouch '\(marker)'\ncat\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temp.path + "/filter.sh")
        return (work, marker)
    }

    /// The live probe with a global git config of the test's own, never the user's.
    private static func probe(globalConfig: String) -> ImpactProbe {
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_GLOBAL"] = globalConfig
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        return .live(environment: environment)
    }

    @Test("A filter named by the repository's own config never runs before approval")
    func repositoryFilterDoesNotRun() throws {
        let temp = try TempDirectory()
        let (work, marker) = try Self.filteredRepository(temp)
        try temp.git("config", "filter.evil.clean", temp.path + "/filter.sh", in: work)
        try temp.file("empty-global", "")

        let lines = Self.note("git reset --hard", cwd: work, probe: Self.probe(globalConfig: temp.path + "/empty-global"))
        #expect(!FileManager.default.fileExists(atPath: marker))
        #expect(lines == nil)
        // The other lookups still work: the push line needs no status.
        #expect(Self.note("git push -f nowhere main", cwd: work, probe: Self.probe(globalConfig: temp.path + "/empty-global"))
            == ["Force push to nowhere, branch main"])
        #expect(!FileManager.default.fileExists(atPath: marker))
    }

    @Test("A filter from the user's global config (git-lfs and the like) is trusted; the count stays")
    func globalFilterKeepsCount() throws {
        let temp = try TempDirectory()
        let (work, _) = try Self.filteredRepository(temp)
        try temp.file("global-config", "[filter \"evil\"]\n\tclean = cat\n")
        #expect(Self.note("git reset --hard", cwd: work, probe: Self.probe(globalConfig: temp.path + "/global-config"))
            == ["Discards uncommitted changes in 1 file"])
    }

    @Test("Discarding work: counts from git status")
    func discardLive() throws {
        let temp = try TempDirectory()
        let work = try temp.repository()
        try temp.file("work/.gitignore", "*.log\n")
        try temp.file("work/one.txt")
        try temp.file("work/two.txt")
        try temp.file("work/staged.txt")
        try temp.git("add", ".", in: work)
        try temp.git("commit", "-q", "-m", "files", in: work)
        try temp.file("work/one.txt", "changed")
        try temp.file("work/two.txt", "changed")
        try temp.file("work/staged.txt", "changed")
        try temp.git("add", "staged.txt", in: work)
        try temp.file("work/new.txt")
        try temp.file("work/newdir/a.txt")
        try temp.file("work/newdir/b.txt")
        try temp.file("work/build.log")

        #expect(Self.note("git reset --hard", cwd: work) == ["Discards uncommitted changes in 3 files"])
        #expect(Self.note("git checkout -- .", cwd: work) == ["Discards unstaged changes in 2 files under \(work)"])
        #expect(Self.note("git restore one.txt", cwd: work) == ["Discards unstaged changes in 1 file in one.txt"])
        #expect(Self.note("git clean -f", cwd: work) == ["Deletes 1 untracked item"])
        #expect(Self.note("git clean -fd", cwd: work) == ["Deletes 3 untracked items"])
        #expect(Self.note("git clean -fdx", cwd: work) == ["Deletes 4 untracked or ignored items"])
        #expect(Self.note("git clean -fX", cwd: work) == ["Deletes 1 ignored item"])

        try temp.git("stash", "-q", "-u", in: work)
        #expect(Self.note("git reset --hard", cwd: work) == ["No uncommitted changes to discard"])
    }

    @Test("Outside a repository, git lookups fail and nothing is said")
    func notARepository() throws {
        let temp = try TempDirectory()
        #expect(Self.note("git reset --hard", cwd: temp.path) == nil)
        #expect(Self.note("git push -f", cwd: temp.path) == nil)
    }

    // MARK: Live probes: files

    @Test("rm -rf: kind, count, symlinks not followed, missing targets, project root")
    func removalLive() throws {
        let temp = try TempDirectory()
        let project = temp.path + "/project"
        for index in 0..<20 { try temp.file("project/build/f\(index).txt") }
        try temp.file("project/build/sub/deep.txt")
        // A link to a big folder outside: counted as one item, not entered.
        for index in 0..<50 { try temp.file("big/f\(index)") }
        try FileManager.default.createSymbolicLink(atPath: project + "/build/link", withDestinationPath: temp.path + "/big")
        try FileManager.default.createSymbolicLink(atPath: project + "/alias", withDestinationPath: temp.path + "/big")
        try temp.file("project/notes.txt")

        let lines = try #require(Self.note(
            "rm -rf build alias missing", cwd: project, projectRoot: project, home: "/nonexistent-home"
        ))
        #expect(lines == [
            "\(project)/build: folder, 23 items",
            "\(project)/alias: symlink, only the link is removed",
            "\(project)/missing: not found",
        ])
        #expect(Self.note("rm -r ../big", cwd: project, projectRoot: project, home: "/nonexistent-home")
            == ["\(temp.path)/big: folder, 50 items, outside the project"])
        #expect(Self.note("rm -rf notes.txt", cwd: project, projectRoot: project, home: "/nonexistent-home")
            == ["\(project)/notes.txt: file"])
        // `..` after a symlink goes where the kernel says: alias/.. is temp, not project.
        #expect(Self.note("rm -rf alias/../big", cwd: project, projectRoot: project, home: "/nonexistent-home")
            == ["\(temp.path)/big: folder, 50 items, outside the project"])
        #expect(Self.note("rm -rf .", cwd: project, projectRoot: project)?.first?.hasSuffix("rm refuses . and ..") == true)
    }

    @Test("A project root reached through a symlink (/tmp → /private/tmp) still counts as the project")
    func symlinkedProjectRoot() throws {
        let temp = try TempDirectory()
        try temp.file("project/build/a")
        try FileManager.default.createSymbolicLink(atPath: temp.path + "/via", withDestinationPath: temp.path + "/project")
        #expect(Self.note("rm -rf build", cwd: temp.path + "/via", projectRoot: temp.path + "/via", home: "/nonexistent-home")
            == ["\(temp.path)/via/build: folder, 1 item"])
        #expect(Self.note("rm -rf \(temp.path)/project/build", cwd: "/", projectRoot: temp.path + "/via", home: "/nonexistent-home")
            == ["\(temp.path)/project/build: folder, 1 item"])
    }

    @Test("rm -rf / and the home folder are called out")
    func dangerousTargets() throws {
        let probe = Self.fake(entries: ["/": .directory, "/Users/me": .directory], count: (10_000, false))
        #expect(Self.note("rm -rf /", cwd: "/Users/me/code/shop", projectRoot: "/Users/me/code/shop", probe: probe)
            == ["/: folder, 10,000+ items, the whole disk"])
        #expect(Self.note(#"rm -rf "$HOME""#, cwd: "/Users/me/code/shop", projectRoot: "/Users/me/code/shop", probe: probe)
            == ["~: folder, 10,000+ items, your home folder"])
    }

    @Test("Counting stops at the cap and never follows symlinks")
    func countingCap() throws {
        let temp = try TempDirectory()
        for index in 0..<60 { try temp.file("many/f\(index)") }
        let far = ContinuousClock.now + .seconds(10)
        #expect(ImpactProbe.countItems(in: temp.path + "/many", cap: 50, deadline: far) == (50, false))
        #expect(ImpactProbe.countItems(in: temp.path + "/many", cap: 1_000, deadline: far) == (60, true))
        try FileManager.default.createSymbolicLink(atPath: temp.path + "/linkdir", withDestinationPath: temp.path + "/many")
        #expect(ImpactProbe.countItems(in: temp.path + "/linkdir", cap: 1_000, deadline: far).count == 0)
        #expect(ImpactProbe.entry(at: temp.path + "/linkdir") == .symlink)
    }

    // MARK: Time budget

    @Test("A program still running at the deadline is stopped and yields nothing")
    func runDeadline() throws {
        let start = ContinuousClock.now
        let output = ImpactProbe.run(
            URL(filePath: "/bin/sleep"), ["5"], in: "/", environment: [:], deadline: start + .milliseconds(100)
        )
        #expect(output == nil)
        #expect(ContinuousClock.now - start < .seconds(1))
    }

    @Test("Counting stops at the deadline")
    func countDeadline() throws {
        let temp = try TempDirectory()
        for index in 0..<600 { try temp.file("many/f\(index)") }
        let result = ImpactProbe.countItems(in: temp.path + "/many", cap: 10_000, deadline: .now - .seconds(1))
        #expect(!result.complete)
        #expect(result.count < 600)
    }

    @Test("The whole note respects its budget; slow lookups are left out")
    func noteBudget() {
        let slow = ImpactProbe(
            git: { _, _, deadline in
                // A git that never answers in time.
                while ContinuousClock.now < deadline { usleep(5_000) }
                return nil
            },
            entry: { _ in .directory },
            countItems: { _, cap, _ in (cap, false) },
            realPath: { $0 }
        )
        let start = ContinuousClock.now
        let lines = Self.note("git push -f && git reset --hard", cwd: "/p", probe: slow, budget: .milliseconds(150))
        #expect(ContinuousClock.now - start < .milliseconds(500))
        #expect(lines == nil)
    }
}
