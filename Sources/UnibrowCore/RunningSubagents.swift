public import Foundation

/// Subagents running in each session, from `SubagentStart` and `SubagentStop`.
///
/// When entries go away:
/// - `SubagentStop` with the same `agent_id`;
/// - `SessionEnd`: the session is gone;
/// - `Stop` or `StopFailure` whose `background_tasks` lists fewer subagents
///   than are tracked: the oldest extra entries are dropped (none listed:
///   all of them). Without `background_tasks` nothing changes;
/// - after `maxAge` without any event from that agent, for a stop that never
///   arrived.
///
/// Not on `UserPromptSubmit` or a plain `Stop`: Claude Code starts subagents
/// in the background by default, and they keep running while the main
/// conversation ends its turn or takes the next prompt.
///
/// Bounded: at most `maxPerSession` agents per session (the oldest go first)
/// and `maxSessions` sessions (the least recently active go first).
public struct RunningSubagents: Sendable, Equatable {
    public struct Agent: Sendable, Hashable {
        public let id: String
        /// `agent_type`, e.g. `Explore`; escaped for display.
        public let type: String?
        public let startedAt: Date
        /// The last hook event from this agent.
        public var lastSeen: Date
    }

    /// What a card shows: `2 agents`, with the types as help text.
    public struct Badge: Sendable, Equatable {
        public let text: String
        public let help: String
    }

    /// Agents per session, oldest first.
    public private(set) var sessions: [String: [Agent]] = [:]

    public static let maxPerSession = 64
    public static let maxSessions = 100
    /// Longer than any real subagent run; only a net for a missed stop.
    public static let maxAge: TimeInterval = 6 * 60 * 60

    public init() {}

    public func count(sessionID: String) -> Int { sessions[sessionID]?.count ?? 0 }

    public func agents(sessionID: String) -> [Agent] { sessions[sessionID] ?? [] }

    /// `nil` when nothing runs in the session.
    public func badge(sessionID: String) -> Badge? {
        let agents = agents(sessionID: sessionID)
        guard !agents.isEmpty else { return nil }
        var types: [String: Int] = [:]
        for agent in agents { types[agent.type ?? "agent", default: 0] += 1 }
        let summary = types.keys.sorted().map { type in
            types[type] == 1 ? type : "\(type) ×\(types[type] ?? 0)"
        }.joined(separator: ", ")
        let noun = agents.count == 1 ? "subagent" : "subagents"
        return Badge(
            text: agents.count == 1 ? "1 agent" : "\(agents.count) agents",
            help: "\(agents.count) \(noun) running: \(summary)"
        )
    }

    /// Applies a hook event. Returns whether anything changed.
    @discardableResult
    public mutating func handle(_ event: HookEvent, payload: HookPayload, now: Date = .now) -> Bool {
        guard let sessionID = payload.sessionID else { return false }
        switch event {
        case .subagentStart:
            guard let id = payload.agentID, !id.isEmpty else { return false }
            start(id: id, type: payload.agentType, sessionID: sessionID, now: now)
            return true
        case .subagentStop:
            guard let id = payload.agentID, var agents = sessions[sessionID],
                  let index = agents.firstIndex(where: { $0.id == id })
            else { return false }
            agents.remove(at: index)
            sessions[sessionID] = agents.isEmpty ? nil : agents
            return true
        case .sessionEnd:
            return sessions.removeValue(forKey: sessionID) != nil
        case .stop, .stopFailure:
            guard let tasks = payload.raw["background_tasks"]?.arrayValue, let agents = sessions[sessionID] else { return false }
            let stillRunning = tasks.filter {
                let type = $0["type"]?.stringValue
                return type == "subagent" || type == "teammate"
            }.count
            guard agents.count > stillRunning else { return false }
            let kept = Array(agents.suffix(stillRunning))
            sessions[sessionID] = kept.isEmpty ? nil : kept
            return true
        default:
            // Any other event from inside a subagent shows it is alive.
            guard let id = payload.agentID, var agents = sessions[sessionID],
                  let index = agents.firstIndex(where: { $0.id == id })
            else { return false }
            agents[index].lastSeen = now
            sessions[sessionID] = agents
            return false
        }
    }

    /// Drops agents not heard from for `maxAge`.
    public mutating func removeExpired(now: Date, maxAge: TimeInterval = Self.maxAge) {
        for (sessionID, agents) in sessions {
            let kept = agents.filter { now.timeIntervalSince($0.lastSeen) <= maxAge }
            if kept.count != agents.count { sessions[sessionID] = kept.isEmpty ? nil : kept }
        }
    }

    public mutating func removeAll() {
        sessions.removeAll()
    }

    private mutating func start(id: String, type: String?, sessionID: String, now: Date) {
        var agents = sessions[sessionID] ?? []
        if let index = agents.firstIndex(where: { $0.id == id }) {
            // Resumed, or a teammate taking its next message: same agent.
            agents[index].lastSeen = now
        } else {
            let label = type.map(ElicitationRequest.label).flatMap { $0.isEmpty ? nil : $0 }
            agents.append(Agent(id: id, type: label, startedAt: now, lastSeen: now))
            if agents.count > Self.maxPerSession { agents.removeFirst(agents.count - Self.maxPerSession) }
        }
        sessions[sessionID] = agents
        if sessions.count > Self.maxSessions {
            let quietest = sessions
                .filter { $0.key != sessionID }
                .min { ($0.value.map(\.lastSeen).max() ?? .distantPast) < ($1.value.map(\.lastSeen).max() ?? .distantPast) }
            if let quietest { sessions[quietest.key] = nil }
        }
    }
}
