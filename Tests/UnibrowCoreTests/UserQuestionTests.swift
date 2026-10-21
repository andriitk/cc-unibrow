import Foundation
import Testing
@testable import UnibrowCore

@Suite("AskUserQuestion")
struct UserQuestionTests {
    private let input = Fixtures.payload("""
    {
      "questions": [
        { "question": "Что именно создать?", "header": "Что создать", "multiSelect": false,
          "options": [ { "label": "Плагин", "description": "Каркас плагина" }, { "label": "Пустая папка" } ] },
        { "question": "Где разместить?", "header": "Место", "multiSelect": true,
          "options": [ { "label": "Корень" }, { "label": "src" } ] }
      ]
    }
    """).raw

    @Test("Questions and options are parsed")
    func parse() throws {
        let questions = try #require(UserQuestion.parse(input))
        #expect(questions.count == 2)
        #expect(questions[0].header == "Что создать")
        #expect(questions[0].options.map(\.label) == ["Плагин", "Пустая папка"])
        #expect(questions[0].options[0].description == "Каркас плагина")
        #expect(questions[1].allowsMultipleAnswers)
    }

    @Test("Malformed input is not treated as a question")
    func malformed() {
        #expect(UserQuestion.parse(.object([:])) == nil)
        #expect(UserQuestion.parse(.object(["questions": .array([.object(["header": .string("x")])])])) == nil)
    }

    @Test("Answers are merged into the input, multiple choices joined")
    func answeredInput() {
        let answered = UserQuestion.answeredInput(input, answers: [
            "Что именно создать?": ["Плагин"],
            "Где разместить?": ["Корень", "src"],
        ])
        #expect(answered["answers"]?["Что именно создать?"] == .string("Плагин"))
        #expect(answered["answers"]?["Где разместить?"] == .string("Корень, src"))
        #expect(answered["questions"] == input["questions"])
    }

    @Test("A question request is flagged and summarised")
    func requestIsQuestion() {
        let request = PendingRequest(sessionID: "s", cwd: "/p", toolName: "AskUserQuestion", toolInput: input)
        #expect(request.isQuestion)
        #expect(ToolSummary(toolName: "AskUserQuestion", input: input).headline == "Что именно создать?")
    }

    @Test("Answering produces allow with updatedInput")
    func hookOutput() throws {
        let output = try #require(HookOutput.permissionRequest(.allowWithInput(updatedInput: .object(["a": .number(1)]))))
        #expect(output["hookSpecificOutput"]?["decision"] == .object([
            "behavior": .string("allow"),
            "updatedInput": .object(["a": .number(1)]),
        ]))
    }
}

@Suite("Display helpers")
struct DisplayHelperTests {
    @Test("Home is abbreviated only on whole path prefixes", arguments: [
        ("mkdir \"/Users/me/x\"", "mkdir \"~/x\""),
        ("cd /Users/me && ls", "cd ~ && ls"),
        ("ls /Users/me", "ls ~"),
        ("ls /Users/meg/x", "ls /Users/meg/x"),
        ("echo \"/Users/me\"", "echo \"~\""),
    ])
    func abbreviateHome(input: String, expected: String) {
        #expect(ToolSummary.abbreviatingHome(input, home: "/Users/me") == expected)
    }

    @Test("Bash headline uses ~ but the detail keeps the exact command")
    func bashKeepsExactDetail() {
        let summary = ToolSummary(toolName: "Bash", input: .object(["command": .string("rm /Users/me/a")]), home: "/Users/me")
        #expect(summary.headline == "rm ~/a")
        #expect(summary.detail == .code("rm /Users/me/a"))
    }

    @Test("Git HEAD parsing", arguments: [
        ("ref: refs/heads/feature/x\n", "feature/x"),
        ("ref: refs/remotes/origin/main", "refs/remotes/origin/main"),
        ("2b7bf5b1234567890\n", "2b7bf5b"),
        ("", nil),
    ] as [(String, String?)])
    func gitHead(head: String, expected: String?) {
        #expect(GitBranch.parse(head: head) == expected)
    }

    @Test("Branch is read from a real repository layout, including worktrees")
    func gitBranchOnDisk() throws {
        let root = URL(filePath: NSTemporaryDirectory()).appending(path: "unibrow-git-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appending(path: "repo")
        try FileManager.default.createDirectory(at: repo.appending(path: ".git"), withIntermediateDirectories: true)
        try "ref: refs/heads/main\n".write(to: repo.appending(path: ".git/HEAD"), atomically: true, encoding: .utf8)
        let nested = repo.appending(path: "src/deep")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        let worktreeGitDir = repo.appending(path: ".git/worktrees/wt")
        try FileManager.default.createDirectory(at: worktreeGitDir, withIntermediateDirectories: true)
        try "ref: refs/heads/wt-branch\n".write(to: worktreeGitDir.appending(path: "HEAD"), atomically: true, encoding: .utf8)
        let worktree = root.appending(path: "wt")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try "gitdir: \(worktreeGitDir.path)\n".write(to: worktree.appending(path: ".git"), atomically: true, encoding: .utf8)

        #expect(GitBranch.current(in: nested.path) == "main")
        #expect(GitBranch.current(in: worktree.path) == "wt-branch")
        #expect(GitBranch.current(in: root.path) == nil)
    }

    @Test("The repository walk always ends, even outside any repository", arguments: [
        "/", "/nonexistent/deep/path/that/does/not/exist", "relative/path", "",
    ])
    func gitWalkTerminates(path: String) {
        // Must return promptly. A walk that never reaches "/" would hang here.
        #expect(GitBranch.repository(containing: path) == nil)
    }

    @Test("Groups report how many sessions they contain")
    func sessionCount() {
        let queue = ApprovalQueue(requests: [
            Fixtures.request(session: "a", cwd: "/p/x"),
            Fixtures.request(session: "b", cwd: "/p/x"),
            Fixtures.request(session: "a", cwd: "/p/x"),
        ])
        #expect(queue.groupedByProject.first?.sessionCount == 2)
    }
}
