import Foundation
import SwiftUI
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

    @Test("A failed session turns the wings red; a request or an agent waiting does not")
    func failureTint() {
        let host = RecordingHost()
        host.queue.append(Requests.bash)
        host.alerts.record(SessionAlert(sessionID: "s2", cwd: "/p", kind: .needsInput(title: nil, message: "Hi")))
        #expect(!host.hasFailure)
        host.alerts.record(SessionAlert(sessionID: "s3", cwd: "/p", kind: .stopFailure(.other("x"), details: nil)))
        #expect(host.hasFailure)
        host.alerts.remove(sessionID: "s3")
        #expect(!host.hasFailure)
    }

    @Test("The indicator: red beats the count, orange counts what waits, green for finished, blue only for updates")
    func indicator() {
        let host = RecordingHost()
        #expect(host.indicator == nil)
        host.finished.record(FinishedSession(sessionID: "u1", cwd: "/p", kind: .update(BackgroundWork(agents: 2))))
        #expect(host.indicator == .update)
        host.finished.record(FinishedSession(sessionID: "s1", cwd: "/p"))
        #expect(host.indicator == .done)
        host.queue.append(Requests.bash)
        host.alerts.record(SessionAlert(sessionID: "s2", cwd: "/p", kind: .needsInput(title: nil, message: "Hi")))
        #expect(host.indicator == .waiting(count: 2))
        host.alerts.record(SessionAlert(sessionID: "s3", cwd: "/p", kind: .stopFailure(.other("x"), details: nil)))
        #expect(host.indicator == .failure)
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

    @Test("An update alone keeps the island open with the blue indicator; the real finish turns it green")
    func updateThenFinish() {
        let host = RecordingHost()
        host.finished.record(FinishedSession(sessionID: "s1", cwd: "/p", kind: .update(BackgroundWork(tasks: 1))))
        #expect(host.hasContent)
        #expect(host.indicator == .update)
        host.finished.record(FinishedSession(sessionID: "s1", cwd: "/p"))
        #expect(host.finished.count == 1)
        #expect(host.indicator == .done)
    }

    @Test("Each row's slot carries its data: the alert, the notice and its kind")
    func slots() {
        let failure = SessionAlert(sessionID: "f", cwd: "/p", kind: .stopFailure(.rateLimit, details: nil))
        let waiting = SessionAlert(sessionID: "w", cwd: "/p", kind: .needsInput(title: nil, message: "Hi"))
        let done = FinishedSession(sessionID: "d", cwd: "/p")
        let update = FinishedSession(sessionID: "u", cwd: "/p", kind: .update(BackgroundWork(agents: 1, tasks: 1)))
        #expect(NotchArtwork.Slot(failure) == .failure(failure))
        #expect(NotchArtwork.Slot(waiting) == .needsInput(waiting))
        #expect(NotchArtwork.Slot(done) == .finished(done))
        #expect(NotchArtwork.Slot(update) == .update(update))
        guard case .update(let notice) = NotchArtwork.Slot(update) else { return }
        #expect(notice.backgroundWork?.total == 2)
    }

    @Test("A host's artwork gets the row's slot, details included")
    func artworkReceivesSlot() {
        final class Seen { var slots: [NotchArtwork.Slot] = [] }
        let seen = Seen()
        let artwork = NotchArtwork(wingWidth: 52, rowWidth: 30) { slot in
            seen.slots.append(slot)
            return AnyView(Color.clear.frame(width: 30, height: 20))
        }
        let update = FinishedSession(sessionID: "u", cwd: "/p", kind: .update(BackgroundWork(agents: 2)))
        let failure = SessionAlert(sessionID: "f", cwd: "/p", kind: .stopFailure(.overloaded, details: nil))
        for slot in [NotchArtwork.Slot(update), NotchArtwork.Slot(failure)] {
            _ = ImageRenderer(content: RowMark(slot: slot).environment(\.notchArtwork, artwork)).nsImage
        }
        #expect(seen.slots == [.update(update), .failure(failure)])
    }

    @Test("The Claude Code glyph: 14 × 8 cells, drawn at a whole number of points per cell")
    func glyph() throws {
        #expect(ClaudeCodeGlyph.rows.count == 8)
        #expect(ClaudeCodeGlyph.rows.allSatisfy { $0.count == ClaudeCodeGlyph.columns && $0.allSatisfy { "#.".contains($0) } })
        #expect(ClaudeCodeGlyph.columns == 14)
        // Same cells as Unibrow Pro's PixelArt.glyph (variant E).
        #expect(ClaudeCodeGlyph.rows.joined().filter { $0 == "#" }.count == 72)

        let renderer = ImageRenderer(content: ClaudeCodeGlyph(cell: 1.5))
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        #expect(image.width == 42)
        #expect(image.height == 24)
    }

    @Test("Unibrow's default artwork is the glyph, so the notch never falls back to symbols")
    func defaultArtwork() {
        let artwork = EnvironmentValues().notchArtwork
        #expect(artwork.wingWidth == 46)
        #expect(artwork.rowWidth == 22)
    }
}
