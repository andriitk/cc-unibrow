import Foundation
import Testing
@testable import UnibrowCore

@Suite("Session alerts")
struct SessionAlertTests {
    @Test("Error kinds map to readable titles", arguments: [
        ("rate_limit", "Rate limit reached"),
        ("overloaded", "The API is overloaded"),
        ("authentication_failed", "Authentication failed"),
        ("oauth_org_not_allowed", "Organization not allowed"),
        ("account_on_hold", "Account on hold"),
        ("billing_error", "Billing problem"),
        ("invalid_request", "Invalid request"),
        ("model_not_found", "Model not found"),
        ("server_error", "API server error"),
        ("max_output_tokens", "Output token limit reached"),
        ("cloud_credential_error", "Cloud credentials could not be loaded"),
        ("unknown", "API error"),
        ("brand_new_error", "API error (brand_new_error)"),
        ("evil\u{1B}[31m", "API error (evil\\u{1B}[31m)"),
    ])
    func errorTitles(raw: String, title: String) {
        #expect(StopFailureKind(raw).title == title)
    }

    @Test("A missing error is a generic API error")
    func missingError() {
        #expect(StopFailureKind(nil).title == "API error")
    }

    @Test("A StopFailure payload becomes an alert with escaped details")
    func stopFailure() throws {
        let payload = Fixtures.payload("""
        {"session_id":"s1","cwd":"/p/shop","hook_event_name":"StopFailure","error":"rate_limit",
         "error_details":"429 Too Many Requests\\u001b[2K","last_assistant_message":"API Error: Rate limit reached"}
        """)
        let alert = try #require(SessionAlert(event: .stopFailure, payload: payload))
        #expect(alert.headline == "Session stopped: Rate limit reached")
        #expect(alert.isFailure)
        #expect(alert.projectName == "shop")
        #expect(alert.kind == .stopFailure(.rateLimit, details: "429 Too Many Requests\\u{1B}[2K\nAPI Error: Rate limit reached"))
    }

    @Test("Identical detail lines are shown once; none means no details")
    func detailsDeduplicated() throws {
        let same = Fixtures.payload(#"{"session_id":"s","error":"overloaded","error_details":"x","last_assistant_message":"x"}"#)
        #expect(SessionAlert(event: .stopFailure, payload: same)?.kind == .stopFailure(.overloaded, details: "x"))
        let none = Fixtures.payload(#"{"session_id":"s","error":"overloaded"}"#)
        #expect(SessionAlert(event: .stopFailure, payload: none)?.kind == .stopFailure(.overloaded, details: nil))
    }

    @Test("agent_needs_input becomes an alert; other notifications do not")
    func needsInput() throws {
        let payload = Fixtures.payload(#"{"session_id":"s1","cwd":"/p","hook_event_name":"Notification","notification_type":"agent_needs_input","message":"Agent \"fixer\" needs​ input","title":"Waiting"}"#)
        let alert = try #require(SessionAlert(event: .notification, payload: payload))
        #expect(alert.headline == "Background agent needs input")
        #expect(alert.kind == .needsInput(title: "Waiting", message: "Agent \"fixer\" needs\\u{200B} input"))
        #expect(!alert.isFailure)

        let idle = Fixtures.payload(#"{"session_id":"s1","notification_type":"idle_prompt","message":"m"}"#)
        #expect(SessionAlert(event: .notification, payload: idle) == nil)
        #expect(SessionAlert(event: .stop, payload: idle) == nil)
        #expect(SessionAlert(event: .stopFailure, payload: Fixtures.payload(#"{"error":"x"}"#)) == nil)
    }

    private func alert(_ session: String, failure: Bool = true, at date: Date = .now) -> SessionAlert {
        SessionAlert(
            sessionID: session,
            cwd: "/p",
            kind: failure ? .stopFailure(.rateLimit, details: nil) : .needsInput(title: nil, message: "m"),
            receivedAt: date
        )
    }

    @Test("One alert per session, newest first")
    func recordReplaces() {
        var alerts = SessionAlerts()
        alerts.record(alert("a"))
        alerts.record(alert("b"))
        alerts.record(alert("a", failure: false))
        #expect(alerts.items.map(\.sessionID) == ["a", "b"])
        #expect(alerts.items.first?.isFailure == false)
    }

    @Test("The session moving on clears its alert", arguments: [
        HookEvent.userPromptSubmit, .stop, .sessionEnd, .permissionRequest, .elicitation,
    ])
    func movingOnClears(event: HookEvent) {
        var alerts = SessionAlerts(items: [alert("a"), alert("b")])
        #expect(alerts.handle(event, sessionID: "a")?.sessionID == "a")
        #expect(alerts.items.map(\.sessionID) == ["b"])
    }

    @Test("Tool activity clears a waiting agent, not a failure")
    func toolActivity() {
        var alerts = SessionAlerts(items: [alert("fail"), alert("wait", failure: false)])
        #expect(alerts.handle(.postToolUse, sessionID: "fail") == nil)
        #expect(alerts.handle(.postToolUse, sessionID: "wait")?.sessionID == "wait")
        #expect(alerts.items.map(\.sessionID) == ["fail"])
    }

    @Test("Old alerts expire and the list is capped")
    func expiryAndCap() {
        let now = Date()
        var alerts = SessionAlerts(items: [alert("old", at: now.addingTimeInterval(-SessionAlerts.maxAge - 1)), alert("new", at: now)])
        alerts.removeExpired(now: now)
        #expect(alerts.items.map(\.sessionID) == ["new"])
        for index in 0..<(SessionAlerts.maxItems + 5) { alerts.record(alert("s\(index)")) }
        #expect(alerts.count == SessionAlerts.maxItems)
    }
}
