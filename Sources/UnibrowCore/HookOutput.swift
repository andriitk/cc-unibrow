import Foundation

/// Builds the JSON a `PermissionRequest` hook prints to stdout.
///
/// See https://code.claude.com/docs/en/hooks — `hookSpecificOutput.decision`.
public enum HookOutput {
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
        case .passthrough:
            return nil
        }

        return .object([
            "hookSpecificOutput": .object([
                "hookEventName": .string(HookEvent.permissionRequest.rawValue),
                "decision": .object(body),
            ]),
        ])
    }
}
