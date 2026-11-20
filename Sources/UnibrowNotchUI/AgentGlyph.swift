import SwiftUI

/// The Claude Code glyph on the left wing: a 14 × 8 pixel drawing, one cell =
/// 2 pt so every cell lands on whole pixels on Retina screens. It always keeps
/// its own colour; the state is the right wing's indicator.
struct AgentGlyph: View {
    /// The drawing's size at one cell = 2 pt.
    static let size = CGSize(width: 28, height: 16)

    var body: some View {
        AgentGlyphShape()
            .fill(Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255))
            .frame(width: Self.size.width, height: Self.size.height)
            .accessibilityLabel("Claude Code")
    }
}

/// The glyph's cells as a shape, scaled to the frame it is given.
struct AgentGlyphShape: Shape {
    /// `#` = filled; the eyes are holes.
    static let rows = [
        "..##########..",
        "..##########..",
        "..##.####.##..",
        "..##.####.##..",
        "##############",
        "##############",
        "...#.#..#.#...",
        "...#.#..#.#...",
    ]

    func path(in rect: CGRect) -> Path {
        let columns = Self.rows[0].count
        let cell = CGSize(width: rect.width / CGFloat(columns), height: rect.height / CGFloat(Self.rows.count))
        var path = Path()
        for (y, row) in Self.rows.enumerated() {
            for (x, mark) in row.enumerated() where mark == "#" {
                path.addRect(CGRect(
                    x: rect.minX + CGFloat(x) * cell.width, y: rect.minY + CGFloat(y) * cell.height,
                    width: cell.width, height: cell.height))
            }
        }
        return path
    }
}
