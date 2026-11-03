import Foundation
import Testing
import UnibrowCore
@testable import UnibrowNotchUI

@MainActor
@Suite("Card text")
struct CardTextTests {
    @Test("Ages read now, seconds, minutes, hours")
    func age() {
        let start = Date(timeIntervalSince1970: 1_000)
        func age(_ seconds: TimeInterval) -> String { CardHeader.age(from: start, to: start + seconds) }
        #expect(age(-5) == "now")
        #expect(age(2) == "now")
        #expect(age(3) == "3s")
        #expect(age(59) == "59s")
        #expect(age(60) == "1m")
        #expect(age(3599) == "59m")
        #expect(age(7200) == "2h")
    }

    @Test("Long chip text keeps its start and end")
    func shortened() {
        #expect(Chip.shortened("main") == "main")
        #expect(Chip.shortened("feature/payment-retries") == "feature/p…nt-retries")
        #expect(Chip.shortened("feature/payment-retries").count == 20)
        #expect(Chip.shortened("abcdefghij", limit: 5) == "ab…ij")
    }

    @Test("Show full … names what the tool would change")
    func noun() {
        #expect(RequestCard.noun(for: "Bash") == "command")
        #expect(RequestCard.noun(for: "MultiEdit") == "change")
        #expect(RequestCard.noun(for: "NotebookEdit") == "content")
        #expect(RequestCard.noun(for: "ExitPlanMode") == "plan")
        #expect(RequestCard.noun(for: "mcp__x__y") == "input")
    }

    @Test("Form placeholders describe the expected value")
    func placeholders() throws {
        let request = PendingRequest(elicitationPayload: Requests.payload("""
        {"session_id":"s1","cwd":"/p","hook_event_name":"Elicitation","mcp_server_name":"m","message":"","mode":"form",
         "requested_schema":{"type":"object","properties":{
           "mail":{"type":"string","format":"email"},
           "note":{"type":"string"},
           "id":{"type":"string"},
           "n":{"type":"integer","minimum":1,"maximum":5},
           "r":{"type":"number","minimum":0.5},
           "k":{"type":"number"}
         },"required":["id"]}}
        """), propertyOrder: ["mail", "note", "id", "n", "r", "k"])
        guard case .form(let form)? = request?.elicitation?.content else {
            Issue.record("Expected a form")
            return
        }
        #expect(form.fields.map { ElicitationCard.placeholder(for: $0) } == [
            "name@example.com", "Optional", "Required", "Whole number, 1–5", "Number, at least 0.5", "Number",
        ])
    }
}
