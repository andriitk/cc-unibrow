public import Foundation

/// Claude Code hook events Unibrow listens to.
///
/// `permissionRequest` and `elicitation` are blocking. `stopFailure` and
/// `notification` (`agent_needs_input`) raise an alert. Every other event is a
/// hint that a pending request may have been answered elsewhere (usually in
/// the terminal).
public enum HookEvent: String, Sendable, Codable, CaseIterable {
    case permissionRequest = "PermissionRequest"
    /// An MCP server asks the user for input (a form or a URL to open).
    case elicitation = "Elicitation"
    case postToolUse = "PostToolUse"
    case postToolUseFailure = "PostToolUseFailure"
    case permissionDenied = "PermissionDenied"
    case userPromptSubmit = "UserPromptSubmit"
    case stop = "Stop"
    case sessionEnd = "SessionEnd"
    /// The turn ended because of an API error (instead of `Stop`).
    case stopFailure = "StopFailure"
    /// Claude Code's notifications; the plugin forwards only `agent_needs_input`.
    case notification = "Notification"

    /// Whether the hook relay must wait for a decision from the app.
    public var expectsDecision: Bool { self == .permissionRequest || self == .elicitation }

    /// How long the relay waits for the user before it prints nothing, so
    /// Claude Code asks in the terminal. `nil`: until Claude Code ends the hook.
    ///
    /// Claude Code shows no elicitation dialog while the hook runs, so an
    /// elicitation waits only `elicitationAnswerSeconds`. That is shorter than
    /// the hook's `timeout` in `hooks.json` (`elicitationHookTimeout`), so the
    /// relay ends on its own with a clean "no decision" instead of being cut
    /// off by Claude Code, which 2.1.299+ may treat as a refusal.
    public var answerDeadline: TimeInterval? {
        self == .elicitation ? Self.elicitationAnswerSeconds : nil
    }

    /// The `timeout` of the `Elicitation` hook in `plugin/hooks/hooks.json`.
    public static let elicitationHookTimeout: TimeInterval = 120
    /// When the relay stops waiting for an elicitation answer.
    public static let elicitationAnswerSeconds: TimeInterval = 110

    /// Whether the app shows something about the session itself, so the relay
    /// adds the git branch and the process chain that leads to the window.
    public var needsSessionDetails: Bool {
        switch self {
        case .permissionRequest, .elicitation, .stop, .stopFailure, .notification: true
        case .postToolUse, .postToolUseFailure, .permissionDenied, .userPromptSubmit, .sessionEnd: false
        }
    }
}

/// Typed view over the JSON object Claude Code writes to a hook's stdin.
///
/// The raw object is kept so that fields we do not model yet survive the trip
/// and fields Claude Code adds later never break decoding.
public struct HookPayload: Sendable, Hashable {
    public let raw: JSONValue

    public init(raw: JSONValue) {
        self.raw = raw
    }

    public init(data: Data) throws {
        let raw = try JSONValue(data: data)
        guard raw.objectValue != nil else { throw HookPayloadError.notAnObject }
        self.raw = raw
    }

    public var sessionID: String? { raw["session_id"]?.stringValue }
    public var transcriptPath: String? { raw["transcript_path"]?.stringValue }
    public var cwd: String? { raw["cwd"]?.stringValue }
    public var hookEventName: String? { raw["hook_event_name"]?.stringValue }
    public var permissionMode: String? { raw["permission_mode"]?.stringValue }
    public var toolName: String? { raw["tool_name"]?.stringValue }
    public var toolInput: JSONValue? { raw["tool_input"] }
    public var toolUseID: String? { raw["tool_use_id"]?.stringValue }
    public var agentType: String? { raw["agent_type"]?.stringValue }
    /// `Notification` only: which notification fired, e.g. `agent_needs_input`.
    public var notificationType: String? { raw["notification_type"]?.stringValue }

    /// "Always allow" rules Claude Code offers for this request, forwarded
    /// verbatim as `updatedPermissions` when the user picks that option.
    public var permissionSuggestions: [JSONValue] {
        raw["permission_suggestions"]?.arrayValue ?? []
    }
}

public enum HookPayloadError: Error, Equatable {
    case notAnObject
}
