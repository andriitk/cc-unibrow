public import Foundation

/// Why Claude Code stopped a turn early (`StopFailure`'s `error`).
public enum StopFailureKind: Sendable, Hashable {
    case rateLimit, overloaded, authenticationFailed, organizationNotAllowed, accountOnHold
    case billing, invalidRequest, modelNotFound, serverError, maxOutputTokens, cloudCredentials
    /// `unknown`, or a value a newer Claude Code adds (kept for display, escaped).
    case other(String)

    public init(_ error: String?) {
        switch error {
        case "rate_limit": self = .rateLimit
        case "overloaded": self = .overloaded
        case "authentication_failed": self = .authenticationFailed
        case "oauth_org_not_allowed": self = .organizationNotAllowed
        case "account_on_hold": self = .accountOnHold
        case "billing_error": self = .billing
        case "invalid_request": self = .invalidRequest
        case "model_not_found": self = .modelNotFound
        case "server_error": self = .serverError
        case "max_output_tokens": self = .maxOutputTokens
        case "cloud_credential_error": self = .cloudCredentials
        default: self = .other(error ?? "unknown")
        }
    }

    /// Short, human-readable reason for the card's title.
    public var title: String {
        switch self {
        case .rateLimit: "Rate limit reached"
        case .overloaded: "The API is overloaded"
        case .authenticationFailed: "Authentication failed"
        case .organizationNotAllowed: "Organization not allowed"
        case .accountOnHold: "Account on hold"
        case .billing: "Billing problem"
        case .invalidRequest: "Invalid request"
        case .modelNotFound: "Model not found"
        case .serverError: "API server error"
        case .maxOutputTokens: "Output token limit reached"
        case .cloudCredentials: "Cloud credentials could not be loaded"
        case .other(let raw) where raw == "unknown" || raw.isEmpty: "API error"
        case .other(let raw): "API error (\(ElicitationRequest.label(raw)))"
        }
    }

    /// What usually helps.
    public var hint: String? {
        switch self {
        case .rateLimit: "Wait for the limit to reset, then continue."
        case .overloaded, .serverError: "Try again in a moment."
        case .authenticationFailed: "Sign in again with /login."
        case .organizationNotAllowed, .accountOnHold, .billing: "Check your account."
        case .modelNotFound: "Pick another model with /model."
        case .maxOutputTokens: "Ask Claude to continue."
        case .cloudCredentials: "Refresh your cloud provider credentials."
        case .invalidRequest, .other: nil
        }
    }
}

/// Something about a session that needs the user, without a request to
/// answer: the turn failed, or a background agent waits for input.
public struct SessionAlert: Sendable, Identifiable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// `StopFailure`: the turn ended on an API error. `details` is
        /// escaped and capped.
        case stopFailure(StopFailureKind, details: String?)
        /// `Notification` / `agent_needs_input` (escaped).
        case needsInput(title: String?, message: String)
    }

    public let sessionID: String
    public let cwd: String
    public let kind: Kind
    public let receivedAt: Date
    public var branch: String?
    public var projectRoot: String?
    public var hostPID: Int32?

    public var id: String { sessionID }

    public init(sessionID: String, cwd: String, kind: Kind, receivedAt: Date = .now) {
        self.sessionID = sessionID
        self.cwd = cwd
        self.kind = kind
        self.receivedAt = receivedAt
    }

    static let maxDetailLength = 2_000

    /// From a `StopFailure` or an `agent_needs_input` notification; `nil` for
    /// anything else.
    public init?(event: HookEvent, payload: HookPayload, receivedAt: Date = .now) {
        guard let sessionID = payload.sessionID else { return nil }
        let kind: Kind
        switch event {
        case .stopFailure:
            let parts = [payload.raw["error_details"]?.stringValue, payload.raw["last_assistant_message"]?.stringValue]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            var unique: [String] = []
            for part in parts where !unique.contains(part) { unique.append(part) }
            let details = unique.isEmpty ? nil : ElicitationRequest.display(unique.joined(separator: "\n"), limit: Self.maxDetailLength).text
            kind = .stopFailure(StopFailureKind(payload.raw["error"]?.stringValue), details: details)
        case .notification where payload.notificationType == "agent_needs_input":
            let message = ElicitationRequest.display(payload.raw["message"]?.stringValue ?? "", limit: 500).text
            let title = payload.raw["title"]?.stringValue.map(ElicitationRequest.label).flatMap { $0.isEmpty ? nil : $0 }
            kind = .needsInput(title: title, message: message)
        default:
            return nil
        }
        self.init(sessionID: sessionID, cwd: payload.cwd ?? "", kind: kind, receivedAt: receivedAt)
    }

    public var isFailure: Bool {
        if case .stopFailure = kind { true } else { false }
    }

    public var projectName: String {
        let name = URL(filePath: cwd).lastPathComponent
        return name.isEmpty || name == "/" ? "Claude Code" : name
    }

    public var sessionTag: String { String(sessionID.prefix(4)) }

    /// "Session stopped: Rate limit reached" or "Background agent needs input".
    public var headline: String {
        switch kind {
        case .stopFailure(let error, _): "Session stopped: \(error.title)"
        case .needsInput: "Background agent needs input"
        }
    }
}

/// Alerts, one per session, newest first.
///
/// An alert goes away when the user opens or dismisses it, when the session
/// moves on (a new prompt, a finished turn, a request, the end of the
/// session), or after `maxAge`.
public struct SessionAlerts: Sendable, Equatable {
    public private(set) var items: [SessionAlert] = []

    public static let maxAge: TimeInterval = 30 * 60
    public static let maxItems = 50

    public init(items: [SessionAlert] = []) {
        self.items = items
    }

    public var isEmpty: Bool { items.isEmpty }
    public var count: Int { items.count }

    /// Adds an alert, replacing an older one from the same session.
    public mutating func record(_ alert: SessionAlert) {
        items.removeAll { $0.sessionID == alert.sessionID }
        items.insert(alert, at: 0)
        if items.count > Self.maxItems { items.removeLast(items.count - Self.maxItems) }
    }

    @discardableResult
    public mutating func remove(sessionID: String) -> SessionAlert? {
        guard let index = items.firstIndex(where: { $0.sessionID == sessionID }) else { return nil }
        return items.remove(at: index)
    }

    public mutating func update(sessionID: String, _ change: (inout SessionAlert) -> Void) {
        guard let index = items.firstIndex(where: { $0.sessionID == sessionID }) else { return }
        change(&items[index])
    }

    /// Removes the session's alert when `event` shows the session moved on.
    /// Returns the removed alert.
    @discardableResult
    public mutating func handle(_ event: HookEvent, sessionID: String) -> SessionAlert? {
        switch event {
        case .userPromptSubmit, .stop, .sessionEnd, .permissionRequest, .elicitation:
            remove(sessionID: sessionID)
        case .postToolUse, .postToolUseFailure, .permissionDenied:
            // Work goes on, so the agent got its input; a failure stays
            // until the user sees it.
            if let alert = items.first(where: { $0.sessionID == sessionID }), !alert.isFailure {
                remove(sessionID: sessionID)
            } else {
                nil
            }
        case .stopFailure, .notification:
            // A new alert replaces the old one through `record`.
            nil
        }
    }

    public mutating func removeExpired(now: Date, maxAge: TimeInterval = Self.maxAge) {
        items.removeAll { now.timeIntervalSince($0.receivedAt) > maxAge }
    }

    public mutating func removeAll() {
        items.removeAll()
    }
}
