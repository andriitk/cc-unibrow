public import SwiftUI

/// Claude Code's mark, drawn cell by cell in Claude's orange (#D97757): the
/// head with two eyes, arms out, four legs, 14 × 8 cells. Code, not an image
/// file, so it stays sharp at any size. Pick `cell` (points) so one cell is a
/// whole number of pixels: 1.5 pt is 3 px on a Retina Mac.
public struct ClaudeCodeGlyph: View {
    /// The cells, one string per row: `#` filled, `.` empty.
    nonisolated public static let rows = [
        "..##########..",
        "..##########..",
        "..##.####.##..",
        "..##.####.##..",
        "##############",
        "##############",
        "...#.#..#.#...",
        "...#.#..#.#...",
    ]
    nonisolated public static let columns = 14
    /// Claude's orange.
    nonisolated public static let color = Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255)

    /// The side of one cell in points.
    public let cell: CGFloat

    public init(cell: CGFloat = 1.5) {
        self.cell = cell
    }

    public var body: some View {
        GlyphShape()
            .fill(Self.color)
            .frame(width: CGFloat(Self.columns) * cell, height: CGFloat(Self.rows.count) * cell)
            .accessibilityLabel("Claude Code")
    }
}

/// The filled cells as one shape, scaled to the frame it gets.
private struct GlyphShape: Shape {
    func path(in rect: CGRect) -> Path {
        let width = rect.width / CGFloat(ClaudeCodeGlyph.columns)
        let height = rect.height / CGFloat(ClaudeCodeGlyph.rows.count)
        var path = Path()
        for (y, row) in ClaudeCodeGlyph.rows.enumerated() {
            for (x, mark) in row.enumerated() where mark == "#" {
                path.addRect(CGRect(x: rect.minX + CGFloat(x) * width, y: rect.minY + CGFloat(y) * height, width: width, height: height))
            }
        }
        return path
    }
}
