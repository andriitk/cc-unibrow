import Foundation

/// Builds the JSON a blocking hook prints to stdout.
///
/// See https://code.claude.com/docs/en/hooks — `PermissionRequest`'s
/// `hookSpecificOutput.decision` and `Elicitation`'s `hookSpecificOutput.action`.
public enum HookOutput {
    /// The stdout payload for `event`, or `nil` when the hook should print
    /// nothing and let Claude Code ask in the terminal. A decision that does
    /// not belong to the event (which would be a bug) also prints nothing.
    public static func output(for event: HookEvent, _ decision: Decision) -> JSONValue? {
        switch event {
        case .permissionRequest: permissionRequest(decision)
        case .elicitation: elicitation(decision)
        default: nil
        }
    }

    /// Returns the stdout payload for a decision, or `nil` when the hook should
    /// print nothing and let Claude Code ask in the terminal.
    public static func permissionRequest(_ decision: Decision) -> JSONValue? {
        let body: [String: JSONValue]
        switch decision {
        case .allow:
            body = ["behavior": .string("allow")]
        case .allowAlways(let updatedPermissions):
            body = updatedPermissions.isEmpty
                ? ["behavior": .string("allow")]
                : ["behavior": .string("allow"), "updatedPermissions": .array(updatedPermissions)]
        case .allowWithInput(let updatedInput):
            body = ["behavior": .string("allow"), "updatedInput": updatedInput]
        case .deny(let message, let interrupt):
            body = [
                "behavior": .string("deny"),
                "message": .string(message),
                "interrupt": .bool(interrupt),
            ]
        case .passthrough, .answerElicitation:
            return nil
        }

        return .object([
            "hookSpecificOutput": .object([
                "hookEventName": .string(HookEvent.permissionRequest.rawValue),
                "decision": .object(body),
            ]),
        ])
    }

    /// `{"hookSpecificOutput": {"hookEventName": "Elicitation", "action": …,
    /// "content": {…}}}`; `content` only for a form's accept.
    public static func elicitation(_ decision: Decision) -> JSONValue? {
        guard case .answerElicitation(let answer) = decision else { return nil }
        var body: [String: JSONValue] = [
            "hookEventName": .string(HookEvent.elicitation.rawValue),
            "action": .string(answer.action),
        ]
        if case .accept(let content) = answer, !content.isEmpty {
            body["content"] = .object(content)
        }
        return .object(["hookSpecificOutput": .object(body)])
    }
}
