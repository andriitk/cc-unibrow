import Foundation
import Testing
import UnibrowCore
@testable import UnibrowNotchUI

@MainActor
@Suite("Notch host seam")
struct NotchHostTests {
    @Test("The island has content while anything waits, alerts or finished")
    func hasContent() {
        let host = RecordingHost()
        #expect(!host.hasContent)

        host.queue.append(Requests.bash)
        #expect(host.hasContent)
        host.queue = ApprovalQueue()

        host.alerts.record(SessionAlert(sessionID: "s2", cwd: "/p", kind: .needsInput(title: nil, message: "Hi")))
        #expect(host.hasContent)
        host.alerts.removeAll()

        host.finished.record(FinishedSession(sessionID: "s3", cwd: "/p"))
        #expect(host.hasContent)
        host.finished.removeAll()
        #expect(!host.hasContent)
    }

    @Test("Each request gets its card")
    func cardKind() throws {
        #expect(CardKind(Requests.bash) == .permission)
        #expect(CardKind(Requests.tool("ExitPlanMode", input: #"{"plan":"x"}"#)) == .permission)

        let questions = try #require(UserQuestion.parse(Requests.question.toolInput))
        #expect(CardKind(Requests.question) == .question(questions))

        let elicitation = try #require(Requests.form.elicitation)
        #expect(CardKind(Requests.form) == .elicitation(elicitation))
    }

    @Test("A question the card cannot read falls back to Allow/Deny")
    func unreadableQuestion() {
        let request = Requests.tool("AskUserQuestion", input: #"{"questions":"not a list"}"#)
        #expect(CardKind(request) == .permission)
    }

    @Test("Every card button reaches the host for its own request")
    func actionsRouteToHost() {
        let host = RecordingHost()
        let request = Requests.bash
        let other = Requests.question
        let actions = CardActions(host: host, request: request)
        _ = CardActions(host: host, request: other)

        actions.decide(.allow)
        actions.decide(.allowAlways)
        actions.decide(.deny)
        actions.answer(["Which?": ["A"]])
        actions.answerElicitation(.decline)
        actions.openLink()
        actions.sendToTerminal()
        actions.bringToFront()

        let id = request.id
        #expect(host.calls == [
            .decide(id, .allow),
            .decide(id, .allowAlways),
            .decide(id, .deny),
            .answer(id, ["Which?": ["A"]]),
            .answerElicitation(id, .decline),
            .openLink(id),
            .sendToTerminal(id),
            .bringToFront(id),
        ])
    }
}
