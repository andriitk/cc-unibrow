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

    @Test("Activity in the session clears its notice", arguments: [HookEvent.userPromptSubmit, .permissionRequest, .elicitation, .stopFailure, .sessionEnd])
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

    // Stop payloads in the shape of Claude Code's hooks reference: the
    // session's in-flight tasks in `background_tasks`.
    static func stop(tasks: String?) -> HookPayload {
        let field = tasks.map { #","background_tasks":\#($0)"# } ?? ""
        return Fixtures.payload("""
        {"session_id":"s1","cwd":"/p/shop","hook_event_name":"Stop","stop_hook_active":false,
         "last_assistant_message":"Started the review."\(field)}
        """)
    }

    static let backgroundAgent = #"{"id":"a1","type":"subagent","status":"running","description":"Review the diff","agent_type":"Explore"}"#
    static let backgroundShell = #"{"id":"b1","type":"shell","status":"running","description":"tail logs","command":"tail -f /var/log/syslog"}"#
    static let endedShell = #"{"id":"b2","type":"shell","status":"completed","description":"make test","command":"make test"}"#

    @Test("A turn that ends while background agents run is an update, not a finish")
    func updateWithAgents() throws {
        let notice = try #require(FinishedSession(stopPayload: Self.stop(tasks: "[\(Self.backgroundAgent),\(Self.backgroundAgent)]")))
        #expect(notice.kind == .update(BackgroundWork(agents: 2)))
        #expect(notice.updateLine == "Claude Code replied · 2 agents still working")
        #expect(notice.summary == "Started the review.")
    }

    @Test("A background shell makes an update too")
    func updateWithShell() throws {
        let notice = try #require(FinishedSession(stopPayload: Self.stop(tasks: "[\(Self.backgroundShell)]")))
        #expect(notice.kind == .update(BackgroundWork(tasks: 1)))
        #expect(notice.updateLine == "Claude Code replied · 1 background task still running")
    }

    @Test("Agents and other tasks together, in plain words")
    func mixedPhrase() {
        #expect(BackgroundWork(agents: 1, tasks: 2).phrase == "1 agent and 2 background tasks still working")
        #expect(BackgroundWork(agents: 1).phrase == "1 agent still working")
        #expect(BackgroundWork().phrase == nil)
    }

    @Test("Nothing running, only ended tasks, or no background_tasks at all: finished", arguments: ["[]", "[\(endedShell)]", nil] as [String?])
    func finishedWhenNothingRuns(tasks: String?) throws {
        let notice = try #require(FinishedSession(stopPayload: Self.stop(tasks: tasks)))
        #expect(notice.kind == .finished)
        #expect(notice.updateLine == nil)
    }

    @Test("A teammate counts as an agent; an unknown task type as a background task")
    func taskTypes() throws {
        let tasks = #"[{"id":"t","type":"teammate","status":"running"},{"id":"m","type":"MCP task"},{"id":"w","type":"workflow","status":"pending"}]"#
        let work = try #require(BackgroundWork(stopPayload: Self.stop(tasks: tasks)))
        #expect(work == BackgroundWork(agents: 1, tasks: 2))
    }

    @Test("The real finish replaces the session's update: one notice per session")
    func finishReplacesUpdate() throws {
        var feed = FinishedSessions()
        feed.record(try #require(FinishedSession(stopPayload: Self.stop(tasks: "[\(Self.backgroundAgent)]"))))
        feed.record(FinishedSession(sessionID: "other", cwd: "/p/other"))
        #expect(feed.updateItems.map(\.sessionID) == ["s1"])
        #expect(feed.finishedItems.map(\.sessionID) == ["other"])

        feed.record(try #require(FinishedSession(stopPayload: Self.stop(tasks: "[]"))))
        #expect(feed.count == 2)
        #expect(feed.updateItems.isEmpty)
        #expect(feed.finishedItems.map(\.sessionID) == ["s1", "other"])
    }

    @Test("A new prompt clears an update like a finished notice")
    func promptClearsUpdate() throws {
        var feed = FinishedSessions()
        feed.record(try #require(FinishedSession(stopPayload: Self.stop(tasks: "[\(Self.backgroundShell)]"))))
        feed.handle(.userPromptSubmit, sessionID: "s1")
        #expect(feed.isEmpty)
    }
}
