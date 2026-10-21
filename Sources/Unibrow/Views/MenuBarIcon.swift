import AppKit

/// The menu bar glyph: the app icon's face — a unibrow over two eyes — drawn
/// as a template image so macOS tints it for light and dark menu bars.
///
/// - Eyes open: watching for requests.
/// - Eyes closed: paused, everything goes to the terminal.
enum MenuBarIcon {
    enum Mood {
        case watching, paused
    }

    /// Cached per mood; drawing is cheap but the label re-renders often.
    @MainActor private static var cache: [Mood: NSImage] = [:]

    @MainActor
    static func image(_ mood: Mood) -> NSImage {
        if let image = cache[mood] { return image }
        let image = draw(mood)
        cache[mood] = image
        return image
    }

    private static func draw(_ mood: Mood) -> NSImage {
        let size = NSSize(width: 22, height: 16)
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setFill()
            NSColor.black.setStroke()

            // Unibrow: two soft arches meeting in a gentle dip, tapered ends.
            let brow = NSBezierPath()
            brow.move(to: NSPoint(x: 1.5, y: 9.2))
            brow.curve(to: NSPoint(x: 7, y: 13.6), controlPoint1: NSPoint(x: 3, y: 11.8), controlPoint2: NSPoint(x: 4.8, y: 13.5))
            brow.curve(to: NSPoint(x: 11, y: 12.7), controlPoint1: NSPoint(x: 9, y: 13.7), controlPoint2: NSPoint(x: 10, y: 12.8))
            brow.curve(to: NSPoint(x: 15, y: 13.6), controlPoint1: NSPoint(x: 12, y: 12.8), controlPoint2: NSPoint(x: 13, y: 13.7))
            brow.curve(to: NSPoint(x: 20.5, y: 9.2), controlPoint1: NSPoint(x: 17.2, y: 13.5), controlPoint2: NSPoint(x: 19, y: 11.8))
            brow.curve(to: NSPoint(x: 15, y: 11.4), controlPoint1: NSPoint(x: 18.8, y: 10.6), controlPoint2: NSPoint(x: 17, y: 11.4))
            brow.curve(to: NSPoint(x: 11, y: 10.8), controlPoint1: NSPoint(x: 13.2, y: 11.4), controlPoint2: NSPoint(x: 12, y: 10.8))
            brow.curve(to: NSPoint(x: 7, y: 11.4), controlPoint1: NSPoint(x: 10, y: 10.8), controlPoint2: NSPoint(x: 8.8, y: 11.4))
            brow.curve(to: NSPoint(x: 1.5, y: 9.2), controlPoint1: NSPoint(x: 5, y: 11.4), controlPoint2: NSPoint(x: 3.2, y: 10.6))
            brow.close()
            brow.fill()

            switch mood {
            case .watching:
                for x in [7.0, 15.0] {
                    NSBezierPath(ovalIn: NSRect(x: x - 1.9, y: 3.2, width: 3.8, height: 3.8)).fill()
                }
            case .paused:
                for x in [7.0, 15.0] {
                    let lid = NSBezierPath()
                    lid.lineWidth = 1.5
                    lid.lineCapStyle = .round
                    lid.move(to: NSPoint(x: x - 2.2, y: 5.4))
                    lid.curve(to: NSPoint(x: x + 2.2, y: 5.4), controlPoint1: NSPoint(x: x - 1, y: 4), controlPoint2: NSPoint(x: x + 1, y: 4))
                    lid.stroke()
                }
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Unibrow"
        return image
    }
}
