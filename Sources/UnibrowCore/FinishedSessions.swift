public import Foundation

/// A Claude Code session that finished its turn: an FYI, not a request.
/// Nothing waits for the user; the notch just says "done".
public struct FinishedSession: Sendable, Identifiable, Hashable {
    public let sessionID: String
    public let cwd: String
    public let finishedAt: Date
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
        summary: String? = nil,
        branch: String? = nil,
        projectRoot: String? = nil,
        hostPID: Int32? = nil
    ) {
        self.sessionID = sessionID
        self.cwd = cwd
        self.finishedAt = finishedAt
        self.summary = summary
        self.branch = branch
        self.projectRoot = projectRoot
        self.hostPID = hostPID
    }

    /// Builds a notice from a `Stop` hook payload. Returns `nil` when the
    /// payload is incomplete, or when Claude is continuing because another
    /// Stop hook asked it to (`stop_hook_active`): the turn is not over.
    public init?(stopPayload payload: HookPayload, finishedAt: Date = .now) {
        guard let sessionID = payload.sessionID,
              payload.raw["stop_hook_active"]?.boolValue != true
        else { return nil }
        self.init(
            sessionID: sessionID,
            cwd: payload.cwd ?? "",
            finishedAt: finishedAt,
            summary: payload.raw["last_assistant_message"]?.stringValue.flatMap { Self.summarize($0) }
        )
    }

    public var projectName: String {
        let name = URL(filePath: cwd).lastPathComponent
        return name.isEmpty || name == "/" ? "Claude Code" : name
    }

    public var sessionTag: String { String(sessionID.prefix(4)) }

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

/// The "finished" notices: one per session, newest first, short-lived.
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
        case .postToolUse, .postToolUseFailure, .permissionDenied, .stop, .notification:
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
