import AppKit
import ApplicationServices
import UnibrowCore

/// Raises the exact window a session runs in — e.g. the right one of ten
/// Cursor windows — instead of whatever window of the app was used last.
///
/// macOS only exposes other apps' windows through the Accessibility API, so
/// this is opt-in: without the permission Unibrow falls back to activating
/// the app. With it, Unibrow reads window titles and raises one window;
/// it never reads window contents or sends input.
enum WindowFocus {
    static var isEnabled: Bool { AXIsProcessTrusted() }

    /// Opens System Settings → Privacy & Security → Accessibility, where the
    /// permission can be turned off (an app cannot revoke its own access).
    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Posted system-wide whenever any app's Accessibility access changes.
    static let changedNotification = Notification.Name("com.apple.accessibility.api")

    /// Shows the system prompt that leads to System Settings → Accessibility.
    static func requestAccess() {
        // The value of `kAXTrustedCheckOptionPrompt`; the C global itself is a
        // mutable var that Swift 6 strict concurrency rejects.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Raises the window of `app` whose title best matches the project.
    /// Returns `false` when it cannot (no permission, no matching window,
    /// window on another Space), so the caller can fall back.
    @MainActor
    static func raiseWindow(of app: NSRunningApplication, projectPath: String) -> Bool {
        guard isEnabled else { return false }

        let element = AXUIElementCreateApplication(app.processIdentifier)
        // Never let a hung app freeze the notch.
        AXUIElementSetMessagingTimeout(element, 0.5)

        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement]
        else { return false }

        let titled = windows.compactMap { window -> (window: AXUIElement, title: String)? in
            var title: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title) == .success,
                  let text = title as? String, !text.isEmpty
            else { return nil }
            return (window, text)
        }
        guard let best = WindowTitleMatcher.bestMatch(titles: titled.map(\.title), projectPath: projectPath) else {
            return false
        }

        let window = titled[best].window
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        app.activate()
        return true
    }
}
