public import Foundation

/// Claude Code hook events Unibrow listens to.
///
/// Only `permissionRequest` is blocking. Every other event is a hint that a
/// pending request may have been answered elsewhere (usually in the terminal).
public enum HookEvent: String, Sendable, Codable, CaseIterable {
    case permissionRequest = "PermissionRequest"
    case postToolUse = "PostToolUse"
    case postToolUseFailure = "PostToolUseFailure"
    case permissionDenied = "PermissionDenied"
    case userPromptSubmit = "UserPromptSubmit"
    case stop = "Stop"
    case sessionEnd = "SessionEnd"

    /// Whether the hook relay must wait for a decision from the app.
    public var expectsDecision: Bool { self == .permissionRequest }
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

    /// "Always allow" rules Claude Code offers for this request, forwarded
    /// verbatim as `updatedPermissions` when the user picks that option.
    public var permissionSuggestions: [JSONValue] {
        raw["permission_suggestions"]?.arrayValue ?? []
    }
}

public enum HookPayloadError: Error, Equatable {
    case notAnObject
}
