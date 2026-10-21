import AppKit
import Darwin
import UnibrowCore

/// Finds the app a Claude Code session runs in. Nothing is hard-coded: the
/// answer is the first ancestor of the hook that is a regular, Dock-visible
/// app — Terminal, iTerm, Ghostty, Warp, Cursor, VS Code, any JetBrains IDE,
/// or anything else. See `ProcessAncestry` for how ancestors are found.
enum HostApp {
    @MainActor
    static func firstRegularApp(in candidates: [pid_t]) -> NSRunningApplication? {
        for pid in candidates {
            if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular {
                return app
            }
        }
        return nil
    }
}
