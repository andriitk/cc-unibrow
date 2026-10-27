public import Foundation

/// A permission request waiting for the user.
public struct PendingRequest: Sendable, Identifiable, Hashable {
    public let id: UUID
    public let sessionID: String
    public let cwd: String
    public let toolName: String
    public let toolInput: JSONValue
    public let suggestions: [JSONValue]
    public let receivedAt: Date
    /// Git branch of `cwd` when the request arrived; helps tell apart several
    /// sessions in the same project.
    public var branch: String?
    /// PID of the terminal or IDE app the session runs in, if known.
    public var hostPID: Int32?
    /// Set when a subagent (not the main conversation) asks.
    public var agentType: String?
    /// Root of the git repository the session works in, if any.
    public var projectRoot: String?
    /// Set for an MCP elicitation (an `Elicitation` hook), which waits in the
    /// queue like a permission request but asks for a form or a URL.
    public var elicitation: ElicitationRequest?

    public init(
        id: UUID = UUID(),
        sessionID: String,
        cwd: String,
        toolName: String,
        toolInput: JSONValue,
        suggestions: [JSONValue] = [],
        receivedAt: Date = .now
    ) {
        self.id = id
        self.sessionID = sessionID
        self.cwd = cwd
        self.toolName = toolName
        self.toolInput = toolInput
        self.suggestions = suggestions
        self.receivedAt = receivedAt
    }

    /// Builds a request from a `PermissionRequest` hook payload.
    /// Returns `nil` when required fields are missing.
    public init?(payload: HookPayload, id: UUID = UUID(), receivedAt: Date = .now) {
        guard let sessionID = payload.sessionID, let toolName = payload.toolName else { return nil }
        self.init(
            id: id,
            sessionID: sessionID,
            cwd: payload.cwd ?? "",
            toolName: toolName,
            toolInput: payload.toolInput ?? .object([:]),
            suggestions: payload.permissionSuggestions,
            receivedAt: receivedAt
        )
        agentType = payload.agentType
    }

    /// Builds a request from an `Elicitation` hook payload. The tool name is
    /// the event name, so tool events never match it.
    public init?(elicitationPayload payload: HookPayload, propertyOrder: [String]? = nil, id: UUID = UUID(), receivedAt: Date = .now) {
        guard let sessionID = payload.sessionID,
              let elicitation = ElicitationRequest(payload: payload, propertyOrder: propertyOrder)
        else { return nil }
        self.init(
            id: id,
            sessionID: sessionID,
            cwd: payload.cwd ?? "",
            toolName: HookEvent.elicitation.rawValue,
            toolInput: payload.raw["requested_schema"] ?? .object([:]),
            receivedAt: receivedAt
        )
        self.elicitation = elicitation
        agentType = payload.agentType
    }

    /// When the relay stops waiting and Claude Code asks in the terminal
    /// instead; `nil` for requests that wait until Claude Code ends the hook.
    public var answerDeadline: Date? {
        guard elicitation != nil, let seconds = HookEvent.elicitation.answerDeadline else { return nil }
        return receivedAt.addingTimeInterval(seconds)
    }

    /// Whole seconds left before `answerDeadline` (never negative).
    public func secondsLeft(now: Date) -> Int? {
        answerDeadline.map { max(0, Int($0.timeIntervalSince(now).rounded(.up))) }
    }

    /// Claude asks to leave plan mode and start working.
    public var isPlanApproval: Bool { toolName == "ExitPlanMode" }

    /// Short, stable tag for the session, e.g. `a1b2`.
    public var sessionTag: String { String(sessionID.prefix(4)) }

    /// Whether this request asks the user a question instead of permission.
    public var isQuestion: Bool {
        elicitation == nil && toolName == UserQuestion.toolName && UserQuestion.parse(toolInput) != nil
    }

    /// Project name shown in the UI: the last path component of `cwd`.
    public var projectName: String {
        let name = URL(filePath: cwd).lastPathComponent
        return name.isEmpty || name == "/" ? "Claude Code" : name
    }
}

/// The ordered set of pending requests, plus every rule that removes them.
///
/// A request leaves the queue in one of these ways:
/// - the user answers it in the notch (`remove(id:)`);
/// - its hook connection closes, because Claude Code cancelled the hook after
///   the user answered in the terminal (`remove(id:)`);
/// - a later hook event shows it was answered elsewhere (`resolve(after:)`);
/// - it outlives `maxAge` (`removeExpired(now:)`).
///
/// The type is a plain value with no I/O so the rules can be unit tested.
public struct ApprovalQueue: Sendable, Equatable {
    public private(set) var requests: [PendingRequest] = []

    public init(requests: [PendingRequest] = []) {
        self.requests = requests
    }

    public var isEmpty: Bool { requests.isEmpty }
    public var count: Int { requests.count }

    public func request(id: UUID) -> PendingRequest? {
        requests.first { $0.id == id }
    }

    public mutating func append(_ request: PendingRequest) {
        requests.append(request)
    }

    /// Changes a request in place; does nothing if it is no longer pending.
    public mutating func update(id: UUID, _ change: (inout PendingRequest) -> Void) {
        guard let index = requests.firstIndex(where: { $0.id == id }) else { return }
        change(&requests[index])
    }

    @discardableResult
    public mutating func remove(id: UUID) -> PendingRequest? {
        guard let index = requests.firstIndex(where: { $0.id == id }) else { return nil }
        return requests.remove(at: index)
    }

    /// Removes requests that `event` proves are no longer waiting for the user.
    /// Returns the removed requests so their hook connections can be closed.
    @discardableResult
    public mutating func resolve(after event: HookEvent, payload: HookPayload) -> [PendingRequest] {
        guard let sessionID = payload.sessionID else { return [] }

        switch event {
        case .permissionRequest, .elicitation, .notification:
            return []

        case .postToolUse, .postToolUseFailure, .permissionDenied:
            // The tool ran, failed or was denied, so its prompt was answered.
            // `PermissionRequest` has no `tool_use_id`, so match the oldest
            // request with the same tool and the same input.
            guard let toolName = payload.toolName else { return [] }
            let input = payload.toolInput ?? .object([:])
            guard let index = requests.firstIndex(where: {
                $0.sessionID == sessionID && $0.toolName == toolName && $0.toolInput == input
            }) else { return [] }
            return [requests.remove(at: index)]

        case .userPromptSubmit, .stop, .stopFailure, .sessionEnd:
            // The turn is over (or a new one started): nothing from this
            // session can still be waiting.
            return removeAll { $0.sessionID == sessionID }
        }
    }

    /// Removes every request from a session, e.g. when its process exited.
    @discardableResult
    public mutating func removeSession(_ sessionID: String) -> [PendingRequest] {
        removeAll { $0.sessionID == sessionID }
    }

    /// Removes requests older than `maxAge`, or past their own answer
    /// deadline. A safety net for signals we miss.
    @discardableResult
    public mutating func removeExpired(now: Date, maxAge: TimeInterval) -> [PendingRequest] {
        removeAll { request in
            now.timeIntervalSince(request.receivedAt) > maxAge
                || request.answerDeadline.map { now >= $0 } == true
        }
    }

    /// Requests grouped by project, preserving arrival order in and across groups.
    public var groupedByProject: [(project: String, requests: [PendingRequest], sessionCount: Int)] {
        var order: [String] = []
        var groups: [String: [PendingRequest]] = [:]
        for request in requests {
            if groups[request.cwd] == nil { order.append(request.cwd) }
            groups[request.cwd, default: []].append(request)
        }
        return order.map { cwd in
            let items = groups[cwd] ?? []
            return (items.first?.projectName ?? cwd, items, Set(items.map(\.sessionID)).count)
        }
    }

    private mutating func removeAll(where predicate: (PendingRequest) -> Bool) -> [PendingRequest] {
        let removed = requests.filter(predicate)
        requests.removeAll(where: predicate)
        return removed
    }
}
