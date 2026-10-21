import SwiftUI

/// The island silhouette: flush with the top of the screen, with small concave
/// "shoulders" where it meets the menu bar (like the hardware notch) and
/// rounded bottom corners.
struct IslandShape: Shape {
    var shoulderRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(shoulderRadius, bottomRadius) }
        set {
            shoulderRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let shoulder = min(shoulderRadius, rect.width / 4, rect.height / 2)
        let bottom = min(bottomRadius, (rect.width - 2 * shoulder) / 2, rect.height - shoulder)

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        // Right shoulder curves inwards from the top edge.
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - shoulder, y: rect.minY + shoulder),
            control: CGPoint(x: rect.maxX - shoulder, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - shoulder, y: rect.maxY - bottom))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - shoulder - bottom, y: rect.maxY),
            control: CGPoint(x: rect.maxX - shoulder, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX + shoulder + bottom, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + shoulder, y: rect.maxY - bottom),
            control: CGPoint(x: rect.minX + shoulder, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX + shoulder, y: rect.minY + shoulder))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.minY),
            control: CGPoint(x: rect.minX + shoulder, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}
