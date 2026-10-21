import AppKit

/// Where the notch is on a given screen, in screen coordinates.
///
/// Screens without a notch (external displays, older Macs) get a virtual notch
/// of the same proportions centred under the menu bar, so the app behaves the
/// same everywhere.
struct NotchGeometry: Equatable {
    /// The notch cut-out (or the virtual one), in screen coordinates.
    let notchRect: CGRect
    let screenFrame: CGRect
    let hasHardwareNotch: Bool

    static let virtualNotchSize = CGSize(width: 190, height: 32)

    init(screen: NSScreen) {
        let frame = screen.frame
        screenFrame = frame

        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            // The notch is the gap between the two usable menu-bar areas.
            let height = screen.safeAreaInsets.top
            notchRect = CGRect(x: left.maxX, y: frame.maxY - height, width: right.minX - left.maxX, height: height)
            hasHardwareNotch = true
        } else {
            let size = Self.virtualNotchSize
            notchRect = CGRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height, width: size.width, height: size.height)
            hasHardwareNotch = false
        }
    }

    /// The screen Unibrow lives on: the built-in display with a notch if there
    /// is one, otherwise the screen with the menu bar.
    static func preferredScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.screens.first
    }
}
