public import Foundation

/// The protocol between `unibrow-hook` and the app.
///
/// Transport: a Unix domain stream socket, one connection per hook invocation,
/// newline-delimited JSON (compact JSON never contains a raw newline).
///
/// ```
/// hook ──HookMessage──▶ app                      (every event)
/// hook ◀──DecisionMessage── app                  (PermissionRequest only)
/// ```
///
/// For a permission request the hook keeps the connection open until the app
/// answers. If the app closes the connection without answering, or is not
/// running at all, the hook prints nothing and Claude Code falls back to its
/// regular terminal prompt.
public enum WireProtocol {
    public static let version = 1
    public static let delimiter = UInt8(ascii: "\n")

    public static func frame(_ message: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(message)
        data.append(delimiter)
        return data
    }

    public static func unframe<Message: Decodable>(_ type: Message.Type, from line: Data) throws -> Message {
        try JSONDecoder().decode(type, from: line)
    }
}

/// Sent by the hook relay for every hook event.
public struct HookMessage: Sendable, Codable, Hashable {
    public var version: Int
    public var event: HookEvent
    public var payload: JSONValue
    /// Git branch of the session's `cwd`, read by the hook. The hook runs
    /// inside the user's terminal or IDE, which already has access to the
    /// project folder; the app itself never reads project files, so macOS
    /// never asks to grant it access to Documents, Desktop and so on.
    public var branch: String?
    /// Root of the git repository the session works in (also read by the hook).
    /// Editors focus their window for this folder when asked to open it.
    public var projectRoot: String?
    /// The hook's ancestor PIDs, nearest first. Sent by the hook because an
    /// asynchronous hook has exited by the time the app reads its message.
    public var ancestorPIDs: [Int32]?

    public init(
        event: HookEvent,
        payload: JSONValue,
        branch: String? = nil,
        projectRoot: String? = nil,
        ancestorPIDs: [Int32]? = nil,
        version: Int = WireProtocol.version
    ) {
        self.version = version
        self.event = event
        self.payload = payload
        self.branch = branch
        self.projectRoot = projectRoot
        self.ancestorPIDs = ancestorPIDs
    }
}

/// The app's answer to a permission request.
public struct DecisionMessage: Sendable, Codable, Hashable {
    public var version: Int
    public var decision: Decision

    public init(decision: Decision, version: Int = WireProtocol.version) {
        self.version = version
        self.decision = decision
    }
}

/// What the user chose in the notch.
public enum Decision: Sendable, Hashable {
    /// Run the tool once.
    case allow
    /// Run the tool and apply Claude Code's suggested permission rules
    /// (the "don't ask again" option of the terminal prompt).
    case allowAlways(updatedPermissions: [JSONValue])
    /// Run the tool with a modified input, e.g. `AskUserQuestion` with the
    /// user's answers filled in.
    case allowWithInput(updatedInput: JSONValue)
    /// Refuse the tool. With `interrupt`, Claude stops the turn and waits for
    /// the next prompt instead of trying something else.
    case deny(message: String, interrupt: Bool)
    /// Let Claude Code show its normal terminal prompt.
    case passthrough
}

extension Decision: Codable {
    private enum CodingKeys: String, CodingKey {
        case behavior, updatedPermissions, updatedInput, message, interrupt
    }

    private enum Behavior: String, Codable {
        case allow, allowAlways, allowWithInput, deny, passthrough
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Behavior.self, forKey: .behavior) {
        case .allow:
            self = .allow
        case .allowAlways:
            self = .allowAlways(
                updatedPermissions: try container.decodeIfPresent([JSONValue].self, forKey: .updatedPermissions) ?? []
            )
        case .allowWithInput:
            self = .allowWithInput(updatedInput: try container.decode(JSONValue.self, forKey: .updatedInput))
        case .deny:
            self = .deny(
                message: try container.decodeIfPresent(String.self, forKey: .message) ?? "",
                interrupt: try container.decodeIfPresent(Bool.self, forKey: .interrupt) ?? false
            )
        case .passthrough:
            self = .passthrough
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .allow:
            try container.encode(Behavior.allow, forKey: .behavior)
        case .allowAlways(let updatedPermissions):
            try container.encode(Behavior.allowAlways, forKey: .behavior)
            try container.encode(updatedPermissions, forKey: .updatedPermissions)
        case .allowWithInput(let updatedInput):
            try container.encode(Behavior.allowWithInput, forKey: .behavior)
            try container.encode(updatedInput, forKey: .updatedInput)
        case .deny(let message, let interrupt):
            try container.encode(Behavior.deny, forKey: .behavior)
            try container.encode(message, forKey: .message)
            try container.encode(interrupt, forKey: .interrupt)
        case .passthrough:
            try container.encode(Behavior.passthrough, forKey: .behavior)
        }
    }
}
