import Foundation
import Testing
@testable import UnibrowCore

@Suite("Approval queue")
struct ApprovalQueueTests {
    @Test("A request is built from a PermissionRequest payload")
    func requestFromPayload() throws {
        let request = try #require(PendingRequest(payload: Fixtures.bashRequest))
        #expect(request.sessionID == "s1")
        #expect(request.toolName == "Bash")
        #expect(request.projectName == "shop")
        #expect(request.suggestions.count == 1)
    }

    @Test("A payload without a session or tool is ignored")
    func incompletePayload() {
        #expect(PendingRequest(payload: Fixtures.payload(#"{"tool_name":"Bash"}"#)) == nil)
        #expect(PendingRequest(payload: Fixtures.payload(#"{"session_id":"s"}"#)) == nil)
    }

    @Test("PostToolUse resolves the matching request even with different key order")
    func postToolUseResolvesMatch() throws {
        var queue = ApprovalQueue()
        let target = try #require(PendingRequest(payload: Fixtures.bashRequest))
        let other = Fixtures.request(input: .object(["command": .string("ls")]))
        queue.append(target)
        queue.append(other)

        let removed = queue.resolve(after: .postToolUse, payload: Fixtures.bashPostToolUse)

        #expect(removed.map(\.id) == [target.id])
        #expect(queue.requests.map(\.id) == [other.id])
    }

    @Test("Identical requests resolve one at a time, oldest first")
    func identicalRequestsResolveInOrder() {
        let first = Fixtures.request(receivedAt: .distantPast)
        let second = Fixtures.request()
        var queue = ApprovalQueue(requests: [first, second])
        let payload = Fixtures.payload(#"{"session_id":"s1","tool_name":"Bash","tool_input":{"command":"ls"}}"#)

        #expect(queue.resolve(after: .postToolUseFailure, payload: payload).map(\.id) == [first.id])
        #expect(queue.requests.map(\.id) == [second.id])
    }

    @Test("Tool events from another session never resolve a request")
    func otherSessionIsIgnored() {
        var queue = ApprovalQueue(requests: [Fixtures.request(session: "s1")])
        let payload = Fixtures.payload(#"{"session_id":"s2","tool_name":"Bash","tool_input":{"command":"ls"}}"#)

        #expect(queue.resolve(after: .postToolUse, payload: payload).isEmpty)
        #expect(queue.count == 1)
    }

    @Test("Turn boundaries clear every request of that session", arguments: [HookEvent.stop, .stopFailure, .userPromptSubmit, .sessionEnd])
    func turnBoundaryClearsSession(event: HookEvent) {
        var queue = ApprovalQueue(requests: [
            Fixtures.request(session: "s1", tool: "Bash"),
            Fixtures.request(session: "s1", tool: "Edit"),
            Fixtures.request(session: "s2"),
        ])

        let removed = queue.resolve(after: event, payload: Fixtures.payload(#"{"session_id":"s1"}"#))

        #expect(removed.count == 2)
        #expect(queue.requests.map(\.sessionID) == ["s2"])
    }

    @Test("A PermissionRequest event never resolves anything")
    func permissionRequestDoesNotResolve() {
        var queue = ApprovalQueue(requests: [Fixtures.request()])
        #expect(queue.resolve(after: .permissionRequest, payload: Fixtures.bashRequest).isEmpty)
    }

    @Test("An elicitation waits in the queue; tool events do not resolve it, the turn ending does")
    func elicitationInQueue() throws {
        let elicitation = try #require(PendingRequest(elicitationPayload: ElicitationTests.formPayload))
        var queue = ApprovalQueue(requests: [elicitation])
        let toolEvent = Fixtures.payload(#"{"session_id":"s1","tool_name":"Elicitation","tool_input":{}}"#)
        #expect(queue.resolve(after: .postToolUse, payload: toolEvent).isEmpty)
        #expect(queue.resolve(after: .elicitation, payload: ElicitationTests.formPayload).isEmpty)
        #expect(queue.resolve(after: .notification, payload: Fixtures.payload(#"{"session_id":"s1"}"#)).isEmpty)
        #expect(queue.resolve(after: .userPromptSubmit, payload: Fixtures.payload(#"{"session_id":"s1"}"#)).count == 1)
    }

    @Test("Expired requests are removed")
    func expiry() {
        let now = Date()
        let old = Fixtures.request(receivedAt: now.addingTimeInterval(-120))
        let fresh = Fixtures.request(receivedAt: now.addingTimeInterval(-10))
        var queue = ApprovalQueue(requests: [old, fresh])

        #expect(queue.removeExpired(now: now, maxAge: 60).map(\.id) == [old.id])
        #expect(queue.requests.map(\.id) == [fresh.id])
    }

    @Test("Grouping keeps arrival order within and across projects")
    func grouping() {
        let a1 = Fixtures.request(cwd: "/p/alpha")
        let b1 = Fixtures.request(cwd: "/p/beta")
        let a2 = Fixtures.request(cwd: "/p/alpha")
        let queue = ApprovalQueue(requests: [a1, b1, a2])

        let groups = queue.groupedByProject
        #expect(groups.map(\.project) == ["alpha", "beta"])
        #expect(groups[0].requests.map(\.id) == [a1.id, a2.id])
    }
}
