import Foundation
import Testing
@testable import UnibrowCore

@Suite("Elicitation deadline")
struct ElicitationDeadlineTests {
    @Test("Only elicitations have a deadline, and it ends before the hook timeout")
    func deadlines() {
        #expect(HookEvent.elicitation.answerDeadline == HookEvent.elicitationAnswerSeconds)
        #expect(HookEvent.elicitationAnswerSeconds < HookEvent.elicitationHookTimeout)
        #expect(HookEvent.permissionRequest.answerDeadline == nil)
        #expect(Fixtures.request().answerDeadline == nil)
    }

    @Test("hooks.json: Elicitation times out after 120 s, PermissionRequest after an hour")
    func hooksJSONTimeouts() throws {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "plugin/hooks/hooks.json")
        let hooks = try JSONValue(data: Data(contentsOf: url))["hooks"]
        let timeout = { (event: String) in hooks?[event]?.arrayValue?.first?["hooks"]?.arrayValue?.first?["timeout"]?.doubleValue }
        #expect(timeout("Elicitation") == HookEvent.elicitationHookTimeout)
        #expect(timeout("PermissionRequest") == 3600)
    }

    @Test("The countdown runs from arrival to the deadline")
    func countdown() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let request = try #require(PendingRequest(elicitationPayload: ElicitationTests.formPayload, receivedAt: start))
        #expect(request.answerDeadline == start.addingTimeInterval(HookEvent.elicitationAnswerSeconds))
        #expect(request.secondsLeft(now: start) == Int(HookEvent.elicitationAnswerSeconds))
        #expect(request.secondsLeft(now: start.addingTimeInterval(10.5)) == Int(HookEvent.elicitationAnswerSeconds) - 10)
        #expect(request.secondsLeft(now: start.addingTimeInterval(500)) == 0)
    }

    @Test("An elicitation past its deadline is removed; a permission request is not")
    func expiry() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let elicitation = try #require(PendingRequest(elicitationPayload: ElicitationTests.formPayload, receivedAt: start))
        let permission = Fixtures.request(receivedAt: start)
        var queue = ApprovalQueue(requests: [elicitation, permission])
        #expect(queue.removeExpired(now: start.addingTimeInterval(60), maxAge: 3600).isEmpty)
        let removed = queue.removeExpired(now: start.addingTimeInterval(HookEvent.elicitationAnswerSeconds), maxAge: 3600)
        #expect(removed.map(\.id) == [elicitation.id])
        #expect(queue.requests.map(\.id) == [permission.id])
    }
}
