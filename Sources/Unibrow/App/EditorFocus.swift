import AppKit
import UnibrowCore

/// Focuses the right editor window without any permission, by asking the
/// editor to open the project folder: VS Code-based editors and JetBrains
/// IDEs switch to the window that already has that folder open.
///
/// This only works for editors that behave that way, hence the list below.
/// Terminals would open a *new* window instead, so they are never asked;
/// they rely on `WindowFocus` (Accessibility) or plain activation.
enum EditorFocus {
    /// Editors that focus an existing window when asked to open its folder.
    static func focusesExistingWindow(bundleID: String) -> Bool {
        let exact: Set<String> = [
            "com.microsoft.VSCode",
            "com.microsoft.VSCodeInsiders",
            "com.vscodium",
            "com.todesktop.230313mzl4w4u92", // Cursor
            "com.exafunction.windsurf",
        ]
        if exact.contains(bundleID) { return true }
        // Every JetBrains IDE, plus Android Studio which is built on it.
        return bundleID.hasPrefix("com.jetbrains.") || bundleID == "com.google.android.studio"
    }

    /// Asks the editor to show `folder`. Only call it with a repository root:
    /// opening a subfolder would make the editor open a second window.
    /// Returns `false` when the app is not a supported editor.
    @MainActor
    static func focus(folder: String, in app: NSRunningApplication) -> Bool {
        guard let bundleID = app.bundleIdentifier, focusesExistingWindow(bundleID: bundleID),
              let appURL = app.bundleURL
        else { return false }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(
            [URL(filePath: folder, directoryHint: .isDirectory)],
            withApplicationAt: appURL,
            configuration: configuration
        )
        return true
    }
}
