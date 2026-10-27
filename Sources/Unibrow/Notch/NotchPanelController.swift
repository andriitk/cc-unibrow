import AppKit
import Observation
import SwiftUI

/// UI-only state of the island, separate from the request data in `AppModel`.
@MainActor
@Observable
final class IslandState {
    /// The pointer is over the island and the request list is open.
    var isExpanded = false
    /// The island's current frame in the panel's coordinate space (top-left origin),
    /// reported by the SwiftUI view. Used for hit-testing the click-through panel.
    var islandFrame: CGRect = .zero
    /// Notch size on the current screen; the island grows out of it.
    var notchSize: CGSize = NotchGeometry.virtualNotchSize
    var hasHardwareNotch = false
}

/// Owns the notch panel: positions it on the right screen, makes it
/// click-through everywhere except the island, and expands the island on hover.
@MainActor
final class NotchPanelController {
    private let model: AppModel
    private let state = IslandState()
    private let panel: NotchPanel
    private var monitors: [Any] = []
    private var collapseTask: Task<Void, Never>?

    /// The panel is a fixed canvas; the island animates inside it. This avoids
    /// resizing an NSWindow on every frame of an animation.
    private static let canvasSize = CGSize(width: 620, height: 600)
    private static let hitSlop: CGFloat = 6

    init(model: AppModel) {
        self.model = model
        panel = NotchPanel(contentRect: CGRect(origin: .zero, size: Self.canvasSize))

        let root = NotchRootView(model: model, island: state)
            .frame(width: Self.canvasSize.width, height: Self.canvasSize.height, alignment: .top)
            .environment(\.beginTyping, BeginTypingAction { [weak self] in self?.beginTyping() })
        panel.contentView = FirstMouseHostingView(rootView: root)
    }

    // MARK: - Keyboard

    /// Lets the panel take keyboard focus for a free-text answer. The app is
    /// not activated, so the terminal stays the active app underneath.
    private func beginTyping() {
        panel.acceptsKeyboard = true
        panel.makeKey()
    }

    /// Gives the keyboard back once the island closes.
    private func endTyping() {
        guard panel.acceptsKeyboard else { return }
        panel.acceptsKeyboard = false
        panel.resignKey()
    }

    func show() {
        reposition()
        panel.orderFrontRegardless()
        installMonitors()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
        }
    }

    // MARK: - Layout

    private func reposition() {
        guard let screen = NotchGeometry.preferredScreen() else { return }
        let geometry = NotchGeometry(screen: screen)
        state.notchSize = geometry.notchRect.size
        state.hasHardwareNotch = geometry.hasHardwareNotch

        let size = Self.canvasSize
        let origin = CGPoint(x: geometry.notchRect.midX - size.width / 2, y: geometry.screenFrame.maxY - size.height)
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
    }

    // MARK: - Pointer tracking

    private func installMonitors() {
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .scrollWheel]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.pointerMoved() }
            return event
        }) {
            monitors.append(local)
        }
    }

    private func pointerMoved() {
        let location = NSEvent.mouseLocation
        let frame = panel.frame
        // Panel-local point with a top-left origin, matching SwiftUI.
        let point = CGPoint(x: location.x - frame.minX, y: frame.maxY - location.y)
        let isInside = !state.islandFrame.isEmpty
            && state.islandFrame.insetBy(dx: -Self.hitSlop, dy: -Self.hitSlop).contains(point)

        panel.ignoresMouseEvents = !isInside

        // Typing ended elsewhere (answer sent, focus moved to another app):
        // stop accepting the keyboard so later clicks never steal focus.
        if panel.acceptsKeyboard, !panel.isKeyWindow {
            endTyping()
        }

        if isInside {
            collapseTask?.cancel()
            collapseTask = nil
            if model.hasContent, !state.isExpanded {
                state.isExpanded = true
            }
        } else if state.isExpanded, collapseTask == nil, !panel.isKeyWindow {
            // Never collapse under the user while they are typing an answer.
            // A short grace period so a sloppy pointer does not slam it shut.
            collapseTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled, let self else { return }
                self.state.isExpanded = false
                self.collapseTask = nil
                self.endTyping()
            }
        }
    }
}

/// Asks the notch panel to accept keyboard input (for free-text answers).
struct BeginTypingAction {
    let run: @MainActor () -> Void

    @MainActor func callAsFunction() { run() }
}

// A classic EnvironmentKey rather than `@Entry`: the macro plugin ships only
// with full Xcode, and this project must build with the Command Line Tools.
private struct BeginTypingKey: EnvironmentKey {
    static let defaultValue = BeginTypingAction {}
}

extension EnvironmentValues {
    var beginTyping: BeginTypingAction {
        get { self[BeginTypingKey.self] }
        set { self[BeginTypingKey.self] = newValue }
    }
}

/// Accepts the first click without activating the app, so a single click on
/// Allow works even though the panel never becomes key.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
