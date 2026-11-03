public import Foundation
public import Observation
public import SwiftUI

/// UI-only state of the island, separate from the request data in the
/// `NotchHost`. The panel that hosts `NotchRootView` owns it.
@MainActor
@Observable
public final class IslandState {
    /// The pointer is over the island and the request list is open.
    public var isExpanded = false
    /// The island's current frame in the panel's coordinate space (top-left origin),
    /// reported by the SwiftUI view. Used for hit-testing the click-through panel.
    public var islandFrame: CGRect = .zero
    /// Notch size on the current screen; the island grows out of it.
    public var notchSize: CGSize

    public init(notchSize: CGSize) {
        self.notchSize = notchSize
    }
}

/// Asks the notch panel to accept keyboard input (for free-text answers).
public struct BeginTypingAction: Sendable {
    let run: @MainActor () -> Void

    public init(run: @escaping @MainActor () -> Void) {
        self.run = run
    }

    @MainActor func callAsFunction() { run() }
}

// A classic EnvironmentKey rather than `@Entry`: the macro plugin ships only
// with full Xcode, and this project must build with the Command Line Tools.
private struct BeginTypingKey: EnvironmentKey {
    static let defaultValue = BeginTypingAction {}
}

extension EnvironmentValues {
    /// Set by the panel that hosts `NotchRootView`; without it, text fields
    /// in the notch cannot take the keyboard.
    public var beginTyping: BeginTypingAction {
        get { self[BeginTypingKey.self] }
        set { self[BeginTypingKey.self] = newValue }
    }
}
