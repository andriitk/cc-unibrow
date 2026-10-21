import AppKit

/// A borderless, non-activating panel that sits over the notch.
///
/// Non-activating means clicking Allow or Deny never steals focus from the
/// terminal or editor you are typing in.
final class NotchPanel: NSPanel {
    init(contentRect: CGRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        // Above the menu bar, so the island can grow out of the notch.
        level = .statusBar + 1
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        // Click-through until the pointer is over the island (see NotchPanelController).
        ignoresMouseEvents = true
    }

    /// Off by default: clicking Allow must never pull keyboard focus away
    /// from the terminal. Turned on only while the user types a free-text
    /// answer (see `NotchPanelController.beginTyping()`).
    var acceptsKeyboard = false

    override var canBecomeKey: Bool { acceptsKeyboard }
    override var canBecomeMain: Bool { false }
}
