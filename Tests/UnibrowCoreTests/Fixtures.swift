import Foundation
@testable import UnibrowCore

enum Fixtures {
    static func payload(_ json: String) -> HookPayload {
        // Test fixtures are static literals; a failure here is a bug in the test.
        try! HookPayload(data: Data(json.utf8))
    }

    static let bashRequest = payload("""
    {
      "session_id": "s1",
      "transcript_path": "/tmp/s1.jsonl",
      "cwd": "/Users/me/code/shop",
      "permission_mode": "default",
      "hook_event_name": "PermissionRequest",
      "tool_name": "Bash",
      "tool_input": { "command": "rm -rf node_modules", "description": "Remove node_modules" },
      "permission_suggestions": [
        { "type": "addRules", "rules": [{ "toolName": "Bash", "ruleContent": "rm -rf node_modules" }],
          "behavior": "allow", "destination": "localSettings" }
      ]
    }
    """)

    static let bashPostToolUse = payload("""
    {
      "session_id": "s1",
      "cwd": "/Users/me/code/shop",
      "hook_event_name": "PostToolUse",
      "tool_name": "Bash",
      "tool_use_id": "toolu_1",
      "tool_input": { "description": "Remove node_modules", "command": "rm -rf node_modules" },
      "tool_response": { "stdout": "" }
    }
    """)

    static func request(
        session: String = "s1",
        cwd: String = "/Users/me/code/shop",
        tool: String = "Bash",
        input: JSONValue = .object(["command": .string("ls")]),
        receivedAt: Date = .now
    ) -> PendingRequest {
        PendingRequest(sessionID: session, cwd: cwd, toolName: tool, toolInput: input, receivedAt: receivedAt)
    }
}
