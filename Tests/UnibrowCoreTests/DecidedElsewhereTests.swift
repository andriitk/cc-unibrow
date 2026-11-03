import Foundation
import Testing
@testable import UnibrowCore

/// A card must leave the notch as soon as a hook event proves its request was
/// decided somewhere else (terminal dialog, auto mode, another hook), and
/// never while it is still waiting. Payload shapes follow the hooks reference:
/// `PermissionRequest` has no `tool_use_id`; `PostToolUse`,
/// `PostToolUseFailure`, `PermissionDenied` and each `PostToolBatch` call do.
@Suite("Requests decided elsewhere")
struct DecidedElsewhereTests {
    private static func permissionRequest(_ tool: String, _ input: String, agent: String? = nil) throws -> PendingRequest {
        let agentField = agent.map { #","agent_id":"\#($0)","agent_type":"general-purpose""# } ?? ""
        return try #require(PendingRequest(payload: Fixtures.payload(
            #"{"session_id":"s1","cwd":"/p","hook_event_name":"PermissionRequest","tool_name":"\#(tool)","tool_input":\#(input)\#(agentField)}"#
        )))
    }

    private static func toolEvent(_ tool: String, _ input: String, id: String, agent: String? = nil, mode: String = "default") -> HookPayload {
        let agentField = agent.map { #","agent_id":"\#($0)""# } ?? ""
        return Fixtures.payload(
            #"{"session_id":"s1","permission_mode":"\#(mode)","tool_name":"\#(tool)","tool_input":\#(input),"tool_use_id":"\#(id)"\#(agentField)}"#
        )
    }

    private static func batch(_ calls: [(tool: String, input: String, id: String)], agent: String? = nil) -> HookPayload {
        let agentField = agent.map { #","agent_id":"\#($0)""# } ?? ""
        let list = calls.map {
            #"{"tool_name":"\#($0.tool)","tool_input":\#($0.input),"tool_use_id":"\#($0.id)","tool_response":"output"}"#
        }.joined(separator: ",")
        return Fixtures.payload(#"{"session_id":"s1","hook_event_name":"PostToolBatch","tool_calls":[\#(list)]\#(agentField)}"#)
    }

    private static let build = #"{"command":"docker build .","description":"Build the image"}"#

    private static let questions = #"[{"question":"Which database?","header":"DB","multiSelect":false,"options":[{"label":"Postgres","description":"p"},{"label":"SQLite","description":"s"}]}]"#

    @Test("A long tool approved in the terminal keeps its card until the tool ends, then it goes")
    func longToolApprovedInTerminal() throws {
        let request = try Self.permissionRequest("Bash", Self.build)
        var queue = ApprovalQueue(requests: [request])

        // While the build runs Claude Code fires nothing for it; other
        // sessions' and other tools' events leave the card alone.
        #expect(queue.resolve(after: .postToolUse, payload: Self.toolEvent("Bash", #"{"command":"ls"}"#, id: "t0")).isEmpty)
        #expect(queue.resolve(after: .subagentStart, payload: Fixtures.payload(#"{"session_id":"s1","agent_id":"a"}"#)).isEmpty)
        #expect(queue.count == 1)

        let done = Self.toolEvent("Bash", #"{"description":"Build the image","command":"docker build ."}"#, id: "t1")
        #expect(queue.resolve(after: .postToolUse, payload: done).map(\.id) == [request.id])
        #expect(queue.isEmpty)
    }

    @Test("Auto mode allowing the call resolves its card when the tool reports back")
    func autoModeAllow() throws {
        let request = try Self.permissionRequest("Bash", Self.build)
        var queue = ApprovalQueue(requests: [request])
        let done = Self.toolEvent("Bash", Self.build, id: "t1", mode: "auto")
        #expect(queue.resolve(after: .postToolUse, payload: done).map(\.id) == [request.id])
    }

    @Test("Auto mode denying the call resolves its card")
    func autoModeDeny() throws {
        let request = try Self.permissionRequest("Bash", Self.build)
        var queue = ApprovalQueue(requests: [request])
        let denied = Self.toolEvent("Bash", Self.build, id: "t1", mode: "auto")
        #expect(queue.resolve(after: .permissionDenied, payload: denied).map(\.id) == [request.id])
    }

    @Test("AskUserQuestion answered in the terminal: the run's input carries the answers, the card still goes")
    func questionAnsweredInTerminal() throws {
        let request = try Self.permissionRequest("AskUserQuestion", #"{"questions":\#(Self.questions)}"#)
        var queue = ApprovalQueue(requests: [request])
        let answered = Self.toolEvent(
            "AskUserQuestion",
            #"{"questions":\#(Self.questions),"answers":{"Which database?":"SQLite"}}"#,
            id: "t1"
        )
        #expect(queue.resolve(after: .postToolUse, payload: answered).map(\.id) == [request.id])
    }

    @Test("A different question is not the same call")
    func differentQuestionStays() throws {
        let request = try Self.permissionRequest("AskUserQuestion", #"{"questions":\#(Self.questions)}"#)
        var queue = ApprovalQueue(requests: [request])
        let other = Self.toolEvent("AskUserQuestion", #"{"questions":[{"question":"Which port?","header":"Port","multiSelect":false,"options":[]}],"answers":{}}"#, id: "t1")
        #expect(queue.resolve(after: .postToolUse, payload: other).isEmpty)
        #expect(queue.count == 1)
    }

    @Test("ExitPlanMode decided in the terminal resolves even with an edited plan, or the model's input from the batch")
    func planDecidedInTerminal() throws {
        let injected = #"{"plan":"1. Do it","planFilePath":"/p/.claude/plans/a.md"}"#
        var queue = ApprovalQueue(requests: [try Self.permissionRequest("ExitPlanMode", injected)])
        let edited = Self.toolEvent("ExitPlanMode", #"{"plan":"1. Do it carefully","planFilePath":"/p/.claude/plans/a.md"}"#, id: "t1")
        #expect(queue.resolve(after: .postToolUse, payload: edited).count == 1)

        queue = ApprovalQueue(requests: [try Self.permissionRequest("ExitPlanMode", injected)])
        #expect(queue.resolve(after: .postToolBatch, payload: Self.batch([("ExitPlanMode", "{}", "t2")])).count == 1)
    }

    @Test("Denied in the terminal with feedback (no PostToolUse): the agent's batch resolves the card")
    func deniedInTerminalWithFeedback() throws {
        let request = try Self.permissionRequest("Bash", Self.build)
        var queue = ApprovalQueue(requests: [request])
        let removed = queue.resolve(after: .postToolBatch, payload: Self.batch([
            ("Read", #"{"file_path":"/p/a"}"#, "t1"),
            ("Bash", Self.build, "t2"),
        ]))
        #expect(removed.map(\.id) == [request.id])
    }

    @Test("Two identical pending requests: each call resolves one, and a call reported twice resolves only one")
    func identicalRequests() throws {
        let first = try Self.permissionRequest("Bash", #"{"command":"ls"}"#)
        let second = try Self.permissionRequest("Bash", #"{"command":"ls"}"#)
        var queue = ApprovalQueue(requests: [first, second])

        let call1 = Self.toolEvent("Bash", #"{"command":"ls"}"#, id: "t1")
        #expect(queue.resolve(after: .postToolUse, payload: call1).map(\.id) == [first.id])
        // The same call again (PostToolUseFailure after PostToolUse, or in the batch) leaves the other one.
        #expect(queue.resolve(after: .postToolUseFailure, payload: call1).isEmpty)
        #expect(queue.resolve(after: .postToolBatch, payload: Self.batch([("Bash", #"{"command":"ls"}"#, "t1")])).isEmpty)
        #expect(queue.requests.map(\.id) == [second.id])

        // The batch naming the second call resolves it.
        let both = Self.batch([("Bash", #"{"command":"ls"}"#, "t1"), ("Bash", #"{"command":"ls"}"#, "t2")])
        #expect(queue.resolve(after: .postToolBatch, payload: both).map(\.id) == [second.id])
        #expect(queue.isEmpty)
    }

    @Test("A batch that arrives before its PostToolUse resolves the card once")
    func batchBeforePostToolUse() throws {
        let first = try Self.permissionRequest("Bash", #"{"command":"ls"}"#)
        let second = try Self.permissionRequest("Bash", #"{"command":"ls"}"#)
        var queue = ApprovalQueue(requests: [first, second])
        #expect(queue.resolve(after: .postToolBatch, payload: Self.batch([("Bash", #"{"command":"ls"}"#, "t1")])).map(\.id) == [first.id])
        #expect(queue.resolve(after: .postToolUse, payload: Self.toolEvent("Bash", #"{"command":"ls"}"#, id: "t1")).isEmpty)
        #expect(queue.requests.map(\.id) == [second.id])
    }

    @Test("A subagent's tool events never resolve the main conversation's identical request, and vice versa")
    func subagentsAreSeparate() throws {
        let main = try Self.permissionRequest("Bash", #"{"command":"make test"}"#)
        let sub = try Self.permissionRequest("Bash", #"{"command":"make test"}"#, agent: "a1")
        var queue = ApprovalQueue(requests: [main, sub])

        let subDone = Self.toolEvent("Bash", #"{"command":"make test"}"#, id: "t1", agent: "a1")
        #expect(queue.resolve(after: .postToolUse, payload: subDone).map(\.id) == [sub.id])
        // Another subagent's batch leaves the main request alone.
        #expect(queue.resolve(after: .postToolBatch, payload: Self.batch([("Bash", #"{"command":"make test"}"#, "t2")], agent: "a2")).isEmpty)
        #expect(queue.requests.map(\.id) == [main.id])

        let mainDone = Self.toolEvent("Bash", #"{"command":"make test"}"#, id: "t3")
        #expect(queue.resolve(after: .postToolUse, payload: mainDone).map(\.id) == [main.id])
    }

    @Test("A batch for other tools, or another session, leaves the card waiting")
    func unrelatedBatch() throws {
        var queue = ApprovalQueue(requests: [try Self.permissionRequest("Bash", Self.build)])
        #expect(queue.resolve(after: .postToolBatch, payload: Self.batch([("Bash", #"{"command":"ls"}"#, "t1")])).isEmpty)
        let otherSession = Fixtures.payload(#"{"session_id":"s2","tool_calls":[{"tool_name":"Bash","tool_input":\#(Self.build),"tool_use_id":"t2"}]}"#)
        #expect(queue.resolve(after: .postToolBatch, payload: otherSession).isEmpty)
        #expect(queue.resolve(after: .postToolBatch, payload: Fixtures.payload(#"{"session_id":"s1"}"#)).isEmpty)
        #expect(queue.count == 1)
    }

    @Test("The relay forwards PostToolBatch without tool responses, and with everything else")
    func relayStripsToolResponses() throws {
        let input = Data(#"{"session_id":"s1","agent_id":"a1","tool_calls":[{"tool_name":"Read","tool_input":{"file_path":"/p/a"},"tool_use_id":"t1","tool_response":"1\tsecret"}]}"#.utf8)
        let message = try #require(HookMessage.relayed(
            input: input, eventName: "PostToolBatch",
            repository: { _ in Issue.record("no git lookup"); return nil },
            ancestors: { Issue.record("no process walk"); return [] }
        ))
        #expect(message.event == .postToolBatch)
        let call = try #require(message.payload["tool_calls"]?.arrayValue?.first)
        #expect(call["tool_response"] == nil)
        #expect(call["tool_use_id"] == .string("t1"))
        #expect(call["tool_input"]?["file_path"] == .string("/p/a"))
        #expect(message.payload["agent_id"] == .string("a1"))
        #expect(message.version == WireProtocol.version)
    }

    @Test("PostToolBatch keeps an alert for a failed turn and leaves finished notices alone")
    func batchAndAlerts() throws {
        let failure = try #require(SessionAlert(
            event: .stopFailure,
            payload: Fixtures.payload(#"{"session_id":"s1","error":"rate_limit"}"#)
        ))
        var alerts = SessionAlerts(items: [failure])
        #expect(alerts.handle(.postToolBatch, sessionID: "s1") == nil)
        var finished = FinishedSessions(items: [FinishedSession(sessionID: "s1", cwd: "/p")])
        finished.handle(.postToolBatch, sessionID: "s1")
        #expect(finished.count == 1)
    }
}
