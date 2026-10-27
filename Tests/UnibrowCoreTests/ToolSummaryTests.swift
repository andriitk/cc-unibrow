import Foundation
import Testing
@testable import UnibrowCore

@Suite("Tool summaries")
struct ToolSummaryTests {
    @Test func bash() {
        let summary = ToolSummary(
            toolName: "Bash",
            input: .object(["command": .string("git push\n--force"), "description": .string("Push")])
        )
        #expect(summary.title == "Bash")
        #expect(summary.headline == "git push …")
        #expect(summary.caption == "Push")
        #expect(summary.detail == .code("git push\n--force"))
    }

    @Test("Edit shows a project-relative path and a diff")
    func edit() {
        let summary = ToolSummary(
            toolName: "Edit",
            input: .object([
                "file_path": .string("/repo/src/app.swift"),
                "old_string": .string("a"),
                "new_string": .string("b"),
            ]),
            cwd: "/repo"
        )
        #expect(summary.headline == "src/app.swift")
        #expect(summary.detail == .diff(removed: "a", added: "b"))
    }

    @Test("Paths outside the project stay absolute")
    func pathOutsideProject() {
        #expect(ToolSummary.relativePath("/etc/hosts", to: "/repo") == "/etc/hosts")
        #expect(ToolSummary.relativePath("/repository/x", to: "/repo") == "/repository/x")
    }

    @Test("MCP tools show server and tool")
    func mcp() {
        let summary = ToolSummary(
            toolName: "mcp__github__create_issue",
            input: .object(["title": .string("Bug"), "repo": .string("a/b")])
        )
        #expect(summary.title == "github · create_issue")
        #expect(summary.headline == #"repo: "a/b", title: "Bug""#)
        #expect(summary.symbol == "puzzlepiece.extension")
    }

    @Test("MCP tool names may contain double underscores")
    func mcpNameWithUnderscores() {
        #expect(ToolSummary.parseMCP("mcp__srv__do__thing")?.tool == "do__thing")
        #expect(ToolSummary.parseMCP("Bash") == nil)
    }

    @Test("Unknown tools fall back to their arguments")
    func unknownTool() {
        let summary = ToolSummary(toolName: "Frobnicate", input: .object(["level": .number(3)]))
        #expect(summary.title == "Frobnicate")
        #expect(summary.headline == "level: 3")
    }
}
