import Foundation
import Observation
import UnibrowCore
import UnibrowNotchUI

/// A host that only records what the views asked for.
@MainActor
@Observable
final class RecordingHost: NotchHost {
    enum Call: Equatable {
        case decide(UUID, PermissionChoice)
        case answer(UUID, [String: [String]])
        case answerElicitation(UUID, ElicitationAnswer)
        case openLink(UUID)
        case sendToTerminal(UUID)
        case bringToFront(UUID)
    }

    var queue = ApprovalQueue()
    var alerts = SessionAlerts()
    var finished = FinishedSessions()
    var subagents = RunningSubagents()
    var peek: NotchPeek?
    var showsWindowFocusHint = false
    private(set) var calls: [Call] = []

    func decide(_ request: PendingRequest, _ choice: PermissionChoice) { calls.append(.decide(request.id, choice)) }
    func answer(_ request: PendingRequest, with answers: [String: [String]]) { calls.append(.answer(request.id, answers)) }
    func answerElicitation(_ request: PendingRequest, _ answer: ElicitationAnswer) {
        calls.append(.answerElicitation(request.id, answer))
    }
    func openElicitationLink(_ request: PendingRequest) { calls.append(.openLink(request.id)) }
    func sendToTerminal(_ request: PendingRequest) { calls.append(.sendToTerminal(request.id)) }
    func bringToFront(_ request: PendingRequest) { calls.append(.bringToFront(request.id)) }
    func open(_ alert: SessionAlert) {}
    func dismiss(_ alert: SessionAlert) {}
    func open(_ notice: FinishedSession) {}
    func dismiss(_ notice: FinishedSession) {}
    func clearFinished() {}
    func dismissWindowFocusHint(enable: Bool) {}
}

enum Requests {
    static func payload(_ json: String) -> HookPayload {
        // Static literals; a failure here is a bug in the test.
        try! HookPayload(data: Data(json.utf8))
    }

    static func tool(_ name: String, input: String) -> PendingRequest {
        PendingRequest(payload: payload("""
        {"session_id":"s1","cwd":"/p/shop","hook_event_name":"PermissionRequest","tool_name":"\(name)","tool_input":\(input)}
        """))!
    }

    static let bash = tool("Bash", input: #"{"command":"ls"}"#)

    static let question = tool("AskUserQuestion", input: """
    {"questions":[{"question":"Which?","options":[{"label":"A"},{"label":"B"}]}]}
    """)

    static let form = PendingRequest(elicitationPayload: payload("""
    {"session_id":"s1","cwd":"/p/shop","hook_event_name":"Elicitation","mcp_server_name":"tracker",
     "message":"Name?","mode":"form","requested_schema":{"type":"object","properties":{"name":{"type":"string"}}}}
    """))!
}
