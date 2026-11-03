public import Foundation

/// The protocol between `unibrow-hook` and the app.
///
/// Transport: a Unix domain stream socket, one connection per hook invocation,
/// newline-delimited JSON (compact JSON never contains a raw newline).
///
/// ```
/// hook ──HookMessage──▶ app                      (every event)
/// hook ◀──DecisionMessage── app                  (PermissionRequest, Elicitation)
/// ```
///
/// For a permission request the hook keeps the connection open until the app
/// answers. If the app closes the connection without answering, or is not
/// running at all, the hook prints nothing and Claude Code falls back to its
/// regular terminal prompt.
///
/// Every message carries `version`, the wire version of its sender:
///
/// - 1: the original protocol. Events `PermissionRequest`, `Elicitation`,
///   `PostToolUse`, `PostToolUseFailure`, `PermissionDenied`,
///   `UserPromptSubmit`, `Stop`, `SessionEnd`, `StopFailure`, `Notification`.
/// - 2: adds the events `SubagentStart` and `SubagentStop`. The message shape
///   is unchanged; `agent_id` and `agent_type` travel in `payload` as Claude
///   Code wrote them.
///
/// Optional fields an older reader may ignore are added without a new
/// version: `impact` (a Bash `PermissionRequest` only) is one. So is the
/// event `PostToolBatch`: it is only a hint, and an app that does not know it
/// drops the message, which changes nothing (the relay and the app come from
/// one build; a newer plugin only makes an older relay see an event name it
/// ignores).
///
/// A message without `version` is read as version 1. A receiver accepts every
/// version in `supportedVersions` and drops anything newer (the relay then
/// falls back to the terminal).
public enum WireProtocol {
    public static let version = 2
    public static let supportedVersions = 1...version
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
    /// `Elicitation` only: the form's property names in the order the server
    /// wrote them, read from the raw input (decoded objects lose their order).
    public var propertyOrder: [String]?
    /// `PermissionRequest` for a risky Bash command only: what it would
    /// affect, looked up by the relay in the session's folder (see
    /// `CommandImpact`). Optional and additive: an app that does not know the
    /// field ignores it.
    public var impact: ImpactNote?

    public init(
        event: HookEvent,
        payload: JSONValue,
        branch: String? = nil,
        projectRoot: String? = nil,
        ancestorPIDs: [Int32]? = nil,
        propertyOrder: [String]? = nil,
        impact: ImpactNote? = nil,
        version: Int = WireProtocol.version
    ) {
        self.version = version
        self.event = event
        self.payload = payload
        self.branch = branch
        self.projectRoot = projectRoot
        self.ancestorPIDs = ancestorPIDs
        self.propertyOrder = propertyOrder
        self.impact = impact
    }

    /// Whether this app understands the message's wire version.
    public var isSupported: Bool { WireProtocol.supportedVersions.contains(version) }

    private enum CodingKeys: String, CodingKey {
        case version, event, payload, branch, projectRoot, ancestorPIDs, propertyOrder, impact
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Messages from before the field existed are version 1.
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        event = try container.decode(HookEvent.self, forKey: .event)
        payload = try container.decode(JSONValue.self, forKey: .payload)
        branch = try container.decodeIfPresent(String.self, forKey: .branch)
        projectRoot = try container.decodeIfPresent(String.self, forKey: .projectRoot)
        ancestorPIDs = try container.decodeIfPresent([Int32].self, forKey: .ancestorPIDs)
        propertyOrder = try container.decodeIfPresent([String].self, forKey: .propertyOrder)
        // Information only: a malformed note is dropped, never the request.
        impact = (try? container.decodeIfPresent(ImpactNote.self, forKey: .impact)) ?? nil
    }

    /// What the relay sends for one hook invocation: the hook's raw `input`
    /// untouched (so `agent_id`, `agent_type` and fields Claude Code adds later
    /// reach the app), plus the session details the event needs. `nil` when
    /// the input is not a JSON object or the event is not one Unibrow handles.
    ///
    /// - Parameters:
    ///   - eventName: the hook's argument; falls back to `hook_event_name`.
    ///   - repository: looks up the git repository of the session's `cwd`.
    ///   - ancestors: the relay's process ancestry, nearest first.
    ///   - impact: the impact note for a permission request, given the
    ///     payload and the repository root; called for nothing else.
    public static func relayed(
        input: Data,
        eventName: String?,
        repository: (String) -> GitBranch.Repository?,
        ancestors: () -> [Int32],
        impact: (HookPayload, _ projectRoot: String?) -> ImpactNote? = { _, _ in nil }
    ) -> HookMessage? {
        guard let payload = try? HookPayload(data: input),
              let event = HookEvent(rawValue: eventName ?? payload.hookEventName ?? "")
        else { return nil }
        let details = event.needsSessionDetails
        let repo = details ? payload.cwd.flatMap(repository) : nil
        return HookMessage(
            event: event,
            payload: event == .postToolBatch ? withoutToolResponses(payload.raw) : payload.raw,
            branch: repo?.branch,
            projectRoot: repo?.root,
            ancestorPIDs: details ? ancestors() : nil,
            propertyOrder: event == .elicitation
                ? JSONKeyOrder.keys(in: input, at: ["requested_schema", "properties"])
                : nil,
            impact: event == .permissionRequest ? impact(payload, repo?.root) : nil
        )
    }
}

extension HookMessage {
    /// A `PostToolBatch` payload without each call's `tool_response`: the app
    /// needs only which calls resolved, and a batch's responses (file
    /// contents, command output) can be megabytes. Everything else stays.
    static func withoutToolResponses(_ raw: JSONValue) -> JSONValue {
        guard var object = raw.objectValue, let calls = object["tool_calls"]?.arrayValue else { return raw }
        object["tool_calls"] = .array(calls.map { call in
            guard var fields = call.objectValue else { return call }
            fields["tool_response"] = nil
            return .object(fields)
        })
        return .object(object)
    }
}

/// The app's answer to a permission request or an MCP elicitation.
public struct DecisionMessage: Sendable, Codable, Hashable {
    public var version: Int
    public var decision: Decision

    public init(decision: Decision, version: Int = WireProtocol.version) {
        self.version = version
        self.decision = decision
    }

    private enum CodingKeys: String, CodingKey { case version, decision }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        decision = try container.decode(Decision.self, forKey: .decision)
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
    /// Answer an MCP elicitation (`Elicitation` hook only).
    case answerElicitation(ElicitationAnswer)
    /// Let Claude Code show its normal terminal prompt.
    case passthrough
}

extension Decision: Codable {
    private enum CodingKeys: String, CodingKey {
        case behavior, updatedPermissions, updatedInput, message, interrupt, action, content
    }

    private enum Behavior: String, Codable {
        case allow, allowAlways, allowWithInput, deny, elicitation, passthrough
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
        case .elicitation:
            switch try container.decode(String.self, forKey: .action) {
            case "accept":
                self = .answerElicitation(.accept(
                    content: try container.decodeIfPresent([String: JSONValue].self, forKey: .content) ?? [:]
                ))
            case "decline": self = .answerElicitation(.decline)
            case "cancel": self = .answerElicitation(.cancel)
            default:
                throw DecodingError.dataCorruptedError(forKey: .action, in: container, debugDescription: "Unknown action")
            }
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
        case .answerElicitation(let answer):
            try container.encode(Behavior.elicitation, forKey: .behavior)
            try container.encode(answer.action, forKey: .action)
            if case .accept(let content) = answer {
                try container.encode(content, forKey: .content)
            }
        case .passthrough:
            try container.encode(Behavior.passthrough, forKey: .behavior)
        }
    }
}
