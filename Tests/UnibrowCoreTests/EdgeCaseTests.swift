import Foundation
import Testing
@testable import UnibrowCore

@Suite("Edge cases")
struct EdgeCaseTests {
    @Test("Huge inputs are capped for display only")
    func hugeWriteIsCapped() throws {
        let content = String(repeating: "x", count: ToolSummary.maxDetailLength + 5_000)
        let input: JSONValue = .object(["file_path": .string("/p/big.txt"), "content": .string(content)])
        let summary = ToolSummary(toolName: "Write", input: input, cwd: "/p")

        guard case .code(let shown) = try #require(summary.detail) else {
            Issue.record("Expected a code detail")
            return
        }
        #expect(shown.count < content.count)
        #expect(shown.hasSuffix("5000 more characters"))
        // What Claude Code receives is untouched: the request keeps the full input.
        let request = PendingRequest(sessionID: "s", cwd: "/p", toolName: "Write", toolInput: input)
        #expect(request.toolInput["content"]?.stringValue?.count == content.count)
    }

    @Test("Very long headlines are cut")
    func longHeadline() {
        let command = String(repeating: "a", count: 2_000)
        let summary = ToolSummary(toolName: "Bash", input: .object(["command": .string(command)]))
        #expect(summary.headline.count == ToolSummary.maxHeadlineLength)
    }

    @Test("Subagent requests remember the agent")
    func subagent() throws {
        let payload = Fixtures.payload(#"{"session_id":"s","tool_name":"Bash","tool_input":{},"agent_type":"code-reviewer"}"#)
        let request = try #require(PendingRequest(payload: payload))
        #expect(request.agentType == "code-reviewer")
    }

    @Test("Plan approvals are recognised and summarised")
    func planApproval() {
        let request = PendingRequest(
            sessionID: "s", cwd: "/p", toolName: "ExitPlanMode",
            toolInput: .object(["plan": .string("# Refactor auth\n1. Extract service")])
        )
        #expect(request.isPlanApproval)
        let summary = ToolSummary(toolName: request.toolName, input: request.toolInput)
        #expect(summary.title == "Plan")
        #expect(summary.headline == "Refactor auth …")
    }

    @Test("Unknown future tools still render")
    func unknownTool() {
        let summary = ToolSummary(toolName: "SomethingNew", input: .object([:]))
        #expect(summary.title == "SomethingNew")
        #expect(summary.detail == nil)
    }
}
