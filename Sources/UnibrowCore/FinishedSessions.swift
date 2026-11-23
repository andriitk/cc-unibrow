public import Foundation

/// Background work still running in a session when its turn ended, from the
/// `Stop` payload's `background_tasks` (the session's in-flight tasks, per
/// Claude Code's hooks reference).
public struct BackgroundWork: Sendable, Hashable {
    /// Subagents and teammates (`type` `subagent` or `teammate`).
    public let agents: Int
    /// Everything else: background shells, monitors, workflows, MCP tasks…
    public let tasks: Int

    public init(agents: Int = 0, tasks: Int = 0) {
        self.agents = max(0, agents)
        self.tasks = max(0, tasks)
    }

    public var isEmpty: Bool { agents == 0 && tasks == 0 }
    public var total: Int { agents + tasks }

    /// Task statuses that mean the task is over. Anything else, or no status,
    /// counts as still running: the list holds in-flight tasks.
    static let endedStatuses: Set<String> = ["completed", "failed", "killed", "stopped", "cancelled", "canceled", "error"]

    /// From a `Stop` payload; `nil` when the payload has no `background_tasks`
    /// (an older Claude Code, or its task registry was unreachable), so the
    /// caller can tell "nothing runs" from "unknown".
    public init?(stopPayload payload: HookPayload) {
        guard let list = payload.raw["background_tasks"]?.arrayValue else { return nil }
        var agents = 0
        var tasks = 0
        for task in list {
            if let status = task["status"]?.stringValue?.lowercased(), Self.endedStatuses.contains(status) { continue }
            switch task["type"]?.stringValue {
            case "subagent", "teammate": agents += 1
            default: tasks += 1
            }
        }
        self.init(agents: agents, tasks: tasks)
    }

    /// "2 agents still working", "1 background task still running",
    /// "1 agent and 2 background tasks still working"; `nil` when empty.
    public var phrase: String? {
        let agentText = agents == 1 ? "1 agent" : "\(agents) agents"
        let taskText = tasks == 1 ? "1 background task" : "\(tasks) background tasks"
        switch (agents, tasks) {
        case (0, 0): return nil
        case (_, 0): return "\(agentText) still working"
        case (0, _): return "\(taskText) still running"
        default: return "\(agentText) and \(taskText) still working"
        }
    }
}

/// A Claude Code session that ended its turn: an FYI, not a request.
/// Nothing waits for the user; the notch says "done", or "update" while
/// background work goes on.
public struct FinishedSession: Sendable, Identifiable, Hashable {
    /// Whether the session is done or only replied while work goes on.
    public enum Kind: Sendable, Hashable {
        /// The turn ended and nothing runs in the background.
        case finished
        /// The turn ended while background agents or tasks still run: Claude
        /// replied, but the session is not done. A later `Stop` with nothing
        /// running replaces it with `finished`.
        case update(BackgroundWork)
    }

    public let sessionID: String
    public let cwd: String
    public let finishedAt: Date
    public let kind: Kind
    /// First line of Claude's last message, shortened.
    public let summary: String?
    public var branch: String?
    public var projectRoot: String?
    public var hostPID: Int32?

    public var id: String { sessionID }

    public init(
        sessionID: String,
        cwd: String,
        finishedAt: Date = .now,
        kind: Kind = .finished,
        summary: String? = nil,
        branch: String? = nil,
        projectRoot: String? = nil,
        hostPID: Int32? = nil
    ) {
        self.sessionID = sessionID
        self.cwd = cwd
        self.finishedAt = finishedAt
        self.kind = kind
        self.summary = summary
        self.branch = branch
        self.projectRoot = projectRoot
        self.hostPID = hostPID
    }

    /// Builds a notice from a `Stop` hook payload. Returns `nil` when the
    /// payload is incomplete, or when Claude is continuing because another
    /// Stop hook asked it to (`stop_hook_active`): the turn is not over.
    ///
    /// An `update` when the payload lists background work still running,
    /// else `finished` (also when the payload has no `background_tasks`, as
    /// before). Decided from the payload alone: no file is read, so it adds
    /// no delay.
    public init?(stopPayload payload: HookPayload, finishedAt: Date = .now) {
        guard let sessionID = payload.sessionID,
              payload.raw["stop_hook_active"]?.boolValue != true
        else { return nil }
        let work = BackgroundWork(stopPayload: payload)
        self.init(
            sessionID: sessionID,
            cwd: payload.cwd ?? "",
            finishedAt: finishedAt,
            kind: work.map { $0.isEmpty ? .finished : .update($0) } ?? .finished,
            summary: payload.raw["last_assistant_message"]?.stringValue.flatMap { Self.summarize($0) }
        )
    }

    public var projectName: String {
        let name = URL(filePath: cwd).lastPathComponent
        return name.isEmpty || name == "/" ? "Claude Code" : name
    }

    public var sessionTag: String { String(sessionID.prefix(4)) }

    public var isUpdate: Bool {
        if case .update = kind { true } else { false }
    }

    /// The background work an update waits on; `nil` for a finished session.
    public var backgroundWork: BackgroundWork? {
        if case .update(let work) = kind { work } else { nil }
    }

    /// The update's plain line, "Claude Code replied · 2 agents still
    /// working"; `nil` for a finished session.
    public var updateLine: String? {
        guard let phrase = backgroundWork?.phrase else { return nil }
        return "Claude Code replied · \(phrase)"
    }

    /// The first meaningful line of a Markdown message, without Markdown
    /// syntax, at most `limit` characters.
    static func summarize(_ message: String, limit: Int = 140) -> String? {
        let line = message
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("```") && !$0.allSatisfy { "-*_=|".contains($0) } }
        guard var text = line else { return nil }
        // Leading list markers, quotes and headings.
        while let first = text.first, "#>-*• ".contains(first) {
            text.removeFirst()
        }
        for token in ["**", "__", "`"] {
            text = text.replacingOccurrences(of: token, with: "")
        }
        text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }
}

/// The "finished" and "update" notices: one per session, newest first,
/// short-lived. A session's newer notice replaces its older one in place, so
/// a real finish replaces the session's update.
///
/// A notice disappears when the user starts the next turn in that session,
/// when the session asks for something again or ends, or after `maxAge`.
public struct FinishedSessions: Sendable, Equatable {
    public private(set) var items: [FinishedSession] = []

    /// Notices are an FYI; an old one is just noise.
    public static let maxAge: TimeInterval = 30 * 60
    public static let maxItems = 50

    public init(items: [FinishedSession] = []) {
        self.items = items
    }

    public var isEmpty: Bool { items.isEmpty }
    public var count: Int { items.count }

    /// Sessions that are done.
    public var finishedItems: [FinishedSession] { items.filter { !$0.isUpdate } }
    /// Sessions that replied while background work goes on.
    public var updateItems: [FinishedSession] { items.filter(\.isUpdate) }

    /// Adds a notice, replacing an older one from the same session.
    public mutating func record(_ session: FinishedSession) {
        items.removeAll { $0.sessionID == session.sessionID }
        items.insert(session, at: 0)
        if items.count > Self.maxItems {
            items.removeLast(items.count - Self.maxItems)
        }
    }

    @discardableResult
    public mutating func remove(sessionID: String) -> FinishedSession? {
        guard let index = items.firstIndex(where: { $0.sessionID == sessionID }) else { return nil }
        return items.remove(at: index)
    }

    public mutating func update(sessionID: String, _ change: (inout FinishedSession) -> Void) {
        guard let index = items.firstIndex(where: { $0.sessionID == sessionID }) else { return }
        change(&items[index])
    }

    /// Clears a session's notice when it becomes active again.
    public mutating func handle(_ event: HookEvent, sessionID: String) {
        switch event {
        case .userPromptSubmit, .permissionRequest, .elicitation, .stopFailure, .sessionEnd:
            remove(sessionID: sessionID)
        case .postToolUse, .postToolUseFailure, .permissionDenied, .postToolBatch, .stop, .notification,
             .subagentStart, .subagentStop:
            break
        }
    }

    public mutating func removeExpired(now: Date, maxAge: TimeInterval = Self.maxAge) {
        items.removeAll { now.timeIntervalSince($0.finishedAt) > maxAge }
    }

    public mutating func removeAll() {
        items.removeAll()
    }
}
