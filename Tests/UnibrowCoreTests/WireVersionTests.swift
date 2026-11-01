import Foundation
import Testing
@testable import UnibrowCore

@Suite("Wire versions and subagent events")
struct WireVersionTests {
    private static let subagentInput = Data(#"""
    {"session_id":"s1","cwd":"/Users/me/code/shop","hook_event_name":"SubagentStop",
     "agent_id":"agent-7","agent_type":"Explore","stop_hook_active":false}
    """#.utf8)

    private static func relayed(_ input: Data, event: String?) -> HookMessage? {
        HookMessage.relayed(
            input: input,
            eventName: event,
            repository: { GitBranch.Repository(root: $0, branch: "main") },
            ancestors: { [42, 1] }
        )
    }

    @Test("The relay sends the current wire version")
    func relayEmitsVersion() throws {
        let message = try #require(Self.relayed(Data(#"{"session_id":"s1"}"#.utf8), event: "PostToolUse"))
        let frame = try WireProtocol.frame(message)
        let json = try JSONValue(data: frame.dropLast())
        #expect(json["version"] == .number(Double(WireProtocol.version)))
        #expect(WireProtocol.version == 2)
    }

    @Test("A message without a version is read as version 1 and accepted")
    func oldMessageWithoutVersion() throws {
        let old = Data(#"{"event":"PermissionRequest","payload":{"session_id":"s1"}}"#.utf8)
        let message = try WireProtocol.unframe(HookMessage.self, from: old)
        #expect(message.version == 1)
        #expect(message.event == .permissionRequest)
        #expect(message.isSupported)
    }

    @Test("Versions 1 and 2 are accepted; unknown versions are not", arguments: [
        (0, false), (1, true), (2, true), (3, false),
    ])
    func supportedVersions(version: Int, supported: Bool) throws {
        let line = Data(#"{"event":"Stop","payload":{},"version":\#(version)}"#.utf8)
        #expect(try WireProtocol.unframe(HookMessage.self, from: line).isSupported == supported)
    }

    @Test("A decision without a version still decodes")
    func oldDecision() throws {
        let line = Data(#"{"decision":{"behavior":"allow"}}"#.utf8)
        let message = try WireProtocol.unframe(DecisionMessage.self, from: line)
        #expect(message.decision == .allow)
        #expect(message.version == 1)
    }

    @Test("Subagent events decode, and agent_id and agent_type reach the app untouched", arguments: [
        "SubagentStart", "SubagentStop",
    ])
    func subagentEvents(name: String) throws {
        let message = try #require(Self.relayed(Self.subagentInput, event: name))
        let decoded = try WireProtocol.unframe(HookMessage.self, from: WireProtocol.frame(message).dropLast())
        #expect(decoded.event.rawValue == name)
        #expect(!decoded.event.expectsDecision)
        // Nothing to show, so no git or process lookups.
        #expect(decoded.branch == nil && decoded.ancestorPIDs == nil)
        let payload = HookPayload(raw: decoded.payload)
        #expect(payload.agentID == "agent-7")
        #expect(payload.agentType == "Explore")
        #expect(payload.raw["stop_hook_active"] == .bool(false))
    }

    @Test("A permission request from inside a subagent keeps its agent fields and session details")
    func subagentPermissionRequest() throws {
        let input = Data(#"{"session_id":"s1","cwd":"/p","tool_name":"Bash","tool_input":{"command":"ls"},"agent_id":"a1","agent_type":"general-purpose"}"#.utf8)
        let message = try #require(Self.relayed(input, event: "PermissionRequest"))
        #expect(HookPayload(raw: message.payload).agentID == "a1")
        #expect(HookPayload(raw: message.payload).agentType == "general-purpose")
        #expect(message.branch == "main" && message.projectRoot == "/p")
        #expect(message.ancestorPIDs == [42, 1])
        #expect(message.version == WireProtocol.version)
    }

    @Test("The relay falls back to hook_event_name, and ignores unknown events and bad input")
    func relayedEdgeCases() {
        #expect(Self.relayed(Self.subagentInput, event: nil)?.event == .subagentStop)
        #expect(Self.relayed(Self.subagentInput, event: "PreCompact") == nil)
        #expect(Self.relayed(Data("[1]".utf8), event: "Stop") == nil)
        #expect(Self.relayed(Data("not json".utf8), event: "Stop") == nil)
    }

    @Test("Subagent events leave cards, alerts and finished notices alone", arguments: [
        HookEvent.subagentStart, .subagentStop,
    ])
    func subagentEventsAreIgnored(event: HookEvent) throws {
        let payload = HookPayload(raw: try JSONValue(data: Self.subagentInput))

        var queue = ApprovalQueue(requests: [Fixtures.request(session: "s1")])
        #expect(queue.resolve(after: event, payload: payload).isEmpty)
        #expect(queue.count == 1)

        let waiting = try #require(SessionAlert(
            event: .notification,
            payload: Fixtures.payload(#"{"session_id":"s1","notification_type":"agent_needs_input","message":"m"}"#)
        ))
        var alerts = SessionAlerts(items: [waiting])
        #expect(alerts.handle(event, sessionID: "s1") == nil)
        #expect(alerts.items.count == 1)
        #expect(SessionAlert(event: event, payload: payload) == nil)

        var finished = FinishedSessions(items: [FinishedSession(sessionID: "s1", cwd: "/p")])
        finished.handle(event, sessionID: "s1")
        #expect(finished.count == 1)
    }

    @Test("hooks.json registers every event the relay handles, the new ones async")
    func hooksJSONRegistersEvents() throws {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "plugin/hooks/hooks.json")
        let hooks = try #require(try JSONValue(data: Data(contentsOf: url))["hooks"]?.objectValue)
        for event in HookEvent.allCases {
            #expect(hooks[event.rawValue] != nil, "\(event.rawValue) is not registered")
        }
        for name in ["SubagentStart", "SubagentStop"] {
            let hook = hooks[name]?.arrayValue?.first?["hooks"]?.arrayValue?.first
            #expect(hook?["async"] == .bool(true))
            #expect(hook?["command"]?.stringValue?.hasSuffix("unibrow-hook\" \(name)") == true)
        }
    }
}
