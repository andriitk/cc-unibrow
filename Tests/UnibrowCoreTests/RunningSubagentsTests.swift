import Foundation
import Testing
@testable import UnibrowCore

@Suite("Running subagents")
struct RunningSubagentsTests {
    private static func payload(session: String = "s1", agent: String? = nil, type: String? = nil, extra: [String: JSONValue] = [:]) -> HookPayload {
        var object: [String: JSONValue] = ["session_id": .string(session)]
        if let agent { object["agent_id"] = .string(agent) }
        if let type { object["agent_type"] = .string(type) }
        object.merge(extra) { $1 }
        return HookPayload(raw: .object(object))
    }

    private static func started(_ ids: [String], session: String = "s1", type: String = "Explore", at date: Date = .now) -> RunningSubagents {
        var agents = RunningSubagents()
        for id in ids {
            agents.handle(.subagentStart, payload: payload(session: session, agent: id, type: type), now: date)
        }
        return agents
    }

    @Test("Start and stop by agent_id, per session")
    func startStop() {
        var agents = Self.started(["a", "b"])
        agents.handle(.subagentStart, payload: Self.payload(session: "s2", agent: "c", type: "Plan"))
        #expect(agents.count(sessionID: "s1") == 2)
        #expect(agents.count(sessionID: "s2") == 1)

        let stoppedA = agents.handle(.subagentStop, payload: Self.payload(agent: "a"))
        #expect(stoppedA)
        #expect(agents.agents(sessionID: "s1").map(\.id) == ["b"])
        // The same agent_id in another session is a different agent.
        let stoppedOtherSession = agents.handle(.subagentStop, payload: Self.payload(agent: "c"))
        #expect(!stoppedOtherSession)
        #expect(agents.count(sessionID: "s2") == 1)
    }

    @Test("A duplicate start is one agent; a stop without a start changes nothing")
    func duplicatesAndStrays() {
        var agents = Self.started(["a", "a"])
        #expect(agents.count(sessionID: "s1") == 1)
        let strayStop = agents.handle(.subagentStop, payload: Self.payload(agent: "zzz"))
        #expect(!strayStop)
        let stopWithoutID = agents.handle(.subagentStop, payload: Self.payload())
        #expect(!stopWithoutID)
        let emptyStart = agents.handle(.subagentStart, payload: Self.payload(agent: ""))
        #expect(!emptyStart)
        let startWithoutSession = agents.handle(.subagentStart, payload: HookPayload(raw: .object(["agent_id": .string("x")])))
        #expect(!startWithoutSession)
        #expect(agents.count(sessionID: "s1") == 1)
    }

    @Test("Each session is capped, oldest dropped first; so is the number of sessions")
    func caps() {
        let ids = (0..<(RunningSubagents.maxPerSession + 5)).map { "a\($0)" }
        let agents = Self.started(ids)
        #expect(agents.count(sessionID: "s1") == RunningSubagents.maxPerSession)
        #expect(agents.agents(sessionID: "s1").first?.id == "a5")

        var many = RunningSubagents()
        let start = Date()
        for index in 0..<(RunningSubagents.maxSessions + 10) {
            many.handle(.subagentStart, payload: Self.payload(session: "s\(index)", agent: "a"), now: start.addingTimeInterval(Double(index)))
        }
        #expect(many.sessions.count == RunningSubagents.maxSessions)
        // The quietest sessions went first.
        #expect(many.count(sessionID: "s0") == 0)
        #expect(many.count(sessionID: "s\(RunningSubagents.maxSessions + 9)") == 1)
    }

    @Test("Agents not heard from for maxAge expire; activity keeps them")
    func expiry() {
        let start = Date()
        var agents = Self.started(["old", "busy"], at: start)
        let later = start.addingTimeInterval(RunningSubagents.maxAge - 60)
        // A tool call from inside "busy" refreshes it.
        agents.handle(.postToolUse, payload: Self.payload(agent: "busy"), now: later)
        agents.removeExpired(now: start.addingTimeInterval(RunningSubagents.maxAge + 1))
        #expect(agents.agents(sessionID: "s1").map(\.id) == ["busy"])
        agents.removeExpired(now: later.addingTimeInterval(RunningSubagents.maxAge + 1))
        #expect(agents.sessions.isEmpty)
    }

    @Test("SessionEnd clears the session")
    func sessionEnd() {
        var agents = Self.started(["a", "b"])
        agents.handle(.subagentStart, payload: Self.payload(session: "s2", agent: "c"))
        let ended = agents.handle(.sessionEnd, payload: Self.payload())
        #expect(ended)
        #expect(agents.count(sessionID: "s1") == 0)
        #expect(agents.count(sessionID: "s2") == 1)
    }

    @Test("Background agents outlive a turn: a new prompt or a plain Stop keeps them", arguments: [
        HookEvent.userPromptSubmit, .stop, .stopFailure, .permissionRequest, .notification,
    ])
    func turnEventsKeep(event: HookEvent) {
        var agents = Self.started(["a", "b"])
        agents.handle(event, payload: Self.payload())
        #expect(agents.count(sessionID: "s1") == 2)
    }

    @Test("Stop with background_tasks drops agents it no longer lists", arguments: [HookEvent.stop, .stopFailure])
    func stopReconciles(event: HookEvent) {
        let shell: JSONValue = .object(["id": .string("t1"), "type": .string("shell"), "status": .string("running")])
        let subagent: JSONValue = .object(["id": .string("t2"), "type": .string("subagent"), "status": .string("running")])

        var agents = Self.started(["a", "b", "c"])
        agents.handle(event, payload: Self.payload(extra: ["background_tasks": .array([shell, subagent])]))
        // One subagent still running: the newest is kept.
        #expect(agents.agents(sessionID: "s1").map(\.id) == ["c"])

        agents.handle(event, payload: Self.payload(extra: ["background_tasks": .array([shell])]))
        #expect(agents.count(sessionID: "s1") == 0)
    }

    @Test("The badge counts agents and lists their types, escaped")
    func badge() throws {
        var agents = RunningSubagents()
        #expect(agents.badge(sessionID: "s1") == nil)
        agents.handle(.subagentStart, payload: Self.payload(agent: "a", type: "Explore"))
        #expect(agents.badge(sessionID: "s1") == RunningSubagents.Badge(text: "1 agent", help: "1 subagent running: Explore"))
        agents.handle(.subagentStart, payload: Self.payload(agent: "b", type: "Explore"))
        agents.handle(.subagentStart, payload: Self.payload(agent: "c", type: "evil\u{202E}name"))
        agents.handle(.subagentStart, payload: Self.payload(agent: "d"))
        let badge = try #require(agents.badge(sessionID: "s1"))
        #expect(badge.text == "4 agents")
        #expect(badge.help == "4 subagents running: Explore ×2, agent, evil\\u{202E}name")
    }
}
