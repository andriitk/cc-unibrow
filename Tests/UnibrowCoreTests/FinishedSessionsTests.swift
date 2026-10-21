import Foundation
import Testing
@testable import UnibrowCore

@Suite("Finished sessions")
struct FinishedSessionsTests {
    @Test("A Stop payload becomes a notice with a clean summary")
    func fromStop() throws {
        let payload = Fixtures.payload("""
        {"session_id":"s1","cwd":"/p/shop","hook_event_name":"Stop","stop_hook_active":false,
         "last_assistant_message":"## Done\\n\\n**Fixed** the `login` bug and added tests."}
        """)
        let notice = try #require(FinishedSession(stopPayload: payload))
        #expect(notice.projectName == "shop")
        #expect(notice.summary == "Done")
    }

    @Test("Summaries skip code fences and rules and strip Markdown", arguments: [
        ("```swift\nlet x = 1\n```\nAll green.", "let x = 1"),
        ("---\n- **Updated** the README", "Updated the README"),
        ("> Note: `make install` again", "Note: make install again"),
        ("", nil),
    ] as [(String, String?)])
    func summary(message: String, expected: String?) {
        #expect(FinishedSession.summarize(message) == expected)
    }

    @Test("Long summaries are cut")
    func longSummary() throws {
        let summary = try #require(FinishedSession.summarize(String(repeating: "a", count: 500)))
        #expect(summary.count == 140)
        #expect(summary.hasSuffix("…"))
    }

    @Test("A Stop while another stop hook keeps Claude going is not a finish")
    func stopHookActive() {
        let payload = Fixtures.payload(#"{"session_id":"s1","stop_hook_active":true}"#)
        #expect(FinishedSession(stopPayload: payload) == nil)
    }

    @Test("One notice per session, newest first")
    func recordReplaces() {
        var feed = FinishedSessions()
        feed.record(FinishedSession(sessionID: "a", cwd: "/p/a", summary: "first"))
        feed.record(FinishedSession(sessionID: "b", cwd: "/p/b"))
        feed.record(FinishedSession(sessionID: "a", cwd: "/p/a", summary: "second"))
        #expect(feed.items.map(\.sessionID) == ["a", "b"])
        #expect(feed.items.first?.summary == "second")
    }

    @Test("Activity in the session clears its notice", arguments: [HookEvent.userPromptSubmit, .permissionRequest, .sessionEnd])
    func activityClears(event: HookEvent) {
        var feed = FinishedSessions(items: [FinishedSession(sessionID: "a", cwd: "/p")])
        feed.handle(event, sessionID: "a")
        #expect(feed.isEmpty)
    }

    @Test("Tool events do not clear a notice")
    func toolEventsKeep() {
        var feed = FinishedSessions(items: [FinishedSession(sessionID: "a", cwd: "/p")])
        feed.handle(.postToolUse, sessionID: "a")
        #expect(feed.count == 1)
    }

    @Test("Old notices expire and the list is capped")
    func expiryAndCap() {
        let now = Date()
        var feed = FinishedSessions(items: [
            FinishedSession(sessionID: "old", cwd: "/p", finishedAt: now.addingTimeInterval(-FinishedSessions.maxAge - 1)),
            FinishedSession(sessionID: "new", cwd: "/p", finishedAt: now),
        ])
        feed.removeExpired(now: now)
        #expect(feed.items.map(\.sessionID) == ["new"])

        for index in 0..<(FinishedSessions.maxItems + 10) {
            feed.record(FinishedSession(sessionID: "s\(index)", cwd: "/p"))
        }
        #expect(feed.count == FinishedSessions.maxItems)
    }
}
