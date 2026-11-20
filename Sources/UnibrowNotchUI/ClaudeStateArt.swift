import SwiftUI

/// The notch's left wing: Claude in a pose per state, so the left says what happened and the right wing's indicator
/// says how many. Unibrow Pro's Dynamic Island shows the same drawings.
enum ClaudeState: Sendable {
    /// Something waits for the user.
    case needsYou
    /// A session stopped on a failure.
    case failure
    /// Claude finished.
    case done
}

/// Claude in the pose of a state, drawn cell by cell. `cell` is the side of one cell in points; pick it so a cell is a
/// whole number of pixels (4 px on a @3x iPhone = 4/3 pt, 3 px on a @2x Mac = 1.5 pt) and the edges stay sharp.
struct ClaudeStateArt: View {
    let state: ClaudeState
    let cell: CGFloat

    init(_ state: ClaudeState, cell: CGFloat) {
        self.state = state
        self.cell = cell
    }

    var body: some View {
        let art = PixelArt.of(state)
        ZStack(alignment: .topLeading) {
            ForEach(art.layers) { layer in
                PixelLayer(cells: layer.cells, columns: art.columns, rows: art.rowCount)
                    .fill(Color(
                        red: Double(layer.color >> 16 & 0xFF) / 255, green: Double(layer.color >> 8 & 0xFF) / 255,
                        blue: Double(layer.color & 0xFF) / 255))
            }
        }
        .frame(width: CGFloat(art.columns) * cell, height: CGFloat(art.rowCount) * cell)
        .accessibilityLabel("Claude Code")
    }
}

/// One colour's cells as a shape, scaled to the frame it is given.
private struct PixelLayer: Shape {
    let cells: [PixelArt.Cell]
    let columns: Int
    let rows: Int

    func path(in rect: CGRect) -> Path {
        let width = rect.width / CGFloat(columns)
        let height = rect.height / CGFloat(rows)
        var path = Path()
        for cell in cells {
            path.addRect(CGRect(
                x: rect.minX + CGFloat(cell.x) * width, y: rect.minY + CGFloat(cell.y) * height,
                width: width, height: height))
        }
        return path
    }
}

/// A pixel drawing: one character per cell, `.` = empty, the palette names each colour (0xRRGGBB).
struct PixelArt: Sendable {
    struct Cell: Sendable {
        let x: Int
        let y: Int
    }

    struct Layer: Identifiable, Sendable {
        let color: UInt32
        let cells: [Cell]
        var id: UInt32 { color }
    }

    let columns: Int
    let rowCount: Int
    let layers: [Layer]

    init(palette: [Character: UInt32], rows: [String]) {
        columns = rows.map(\.count).max() ?? 0
        rowCount = rows.count
        var cells: [UInt32: [Cell]] = [:]
        for (y, row) in rows.enumerated() {
            for (x, mark) in row.enumerated() {
                guard let color = palette[mark] else { continue }
                cells[color, default: []].append(Cell(x: x, y: y))
            }
        }
        layers = cells.keys.sorted().map { Layer(color: $0, cells: cells[$0] ?? []) }
    }

    static func of(_ state: ClaudeState) -> PixelArt {
        switch state {
        case .needsYou: needsYou
        case .failure: failure
        case .done: done
        }
    }

    // Generated from the owner's mascot pack (getillustrations.com, licensed for commercial use), one cell per pixel
    // of the original 46 × 46 grid, cropped to the drawing.

    /// Something waits for the owner: Claude holding up an "It depends" sign.
    static let needsYou = PixelArt(
        palette: ["a": 0x2F2F38, "b": 0x8C7670, "c": 0xADED51, "d": 0xD97757, "e": 0xEF509C, "f": 0xFFFFFF],
        rows: [
            ".eeeeeeeeeeeeeeeeeeee.......",
            "eeeececcceeeeeeeeeeeee......",
            "eeeeceeceeeeeeeeeeeeee......",
            "eeeeeeeeeeeeeeeeeeeeee......",
            "eecceeccececceccceccee......",
            "eecececeececeecececece......",
            "eecceecceeeccecececcee......",
            ".eeeeeeeeebeeeeeeeeee.......",
            "..........b.................",
            ".........dddddddddddddddd...",
            ".........dddddddddddddddd...",
            ".........dddddaddddddaddd...",
            "..........bdddddffffddddd...",
            "...........dddddddddddddd...",
            "...........dddddddddddddd...",
            "...........ddddddddddddddddd",
            "...........ddddddddddddddddd",
            "...........ddddddddddddddddd",
            "...........d..d......d..d...",
            "...........d..d......d..d...",
        ])

    /// A session stopped on a failure: Claude next to an error window.
    static let failure = PixelArt(
        palette: ["a": 0x2F2F38, "b": 0xD97757, "c": 0xE5D942, "d": 0xE842E0, "e": 0xEC8FEF, "f": 0xFC277E, "g": 0xFFC0FF, "h": 0xFFFFFF],
        rows: [
            ".dddddddddddddd...............",
            "ddcdcdcddddddddd..............",
            "dddddddddddddddd..............",
            "gggggfgggggggggg..............",
            "ggggfffggggggggg..............",
            "gggffhffgggggggg..............",
            "gggffhffggggfggg..............",
            "ggfffffffgggfgggbbbbbbbbbbbbb.",
            "ggfffhfffgggggggbbbbbbbbbbbbb.",
            "gfffffffffggfgggbabbbabbbbbbb.",
            "ggggggggggggggggbbbbbbbbbbbbb.",
            "gggeeeeeggggggggbbhhhbbbbbbbb.",
            "ggggggggggggggggbbbbbbbbbbbbb.",
            "gggggggggggggbbbbbbbbbbbbbbbb.",
            ".............bbbbbbbbbbbbbbbbb",
            ".............bbbbbbbbbbbbbbbbb",
            "................b..b......b..b",
            "................b..b......b..b",
        ])

    /// Claude finished: arms up under a green check.
    static let done = PixelArt(
        palette: ["a": 0x15AA51, "b": 0x2F2F38, "c": 0x3AEDB2, "d": 0xD97757, "e": 0xFFFFFF],
        rows: [
            ".......aaaaaa.......",
            "...c..aaaaaaaa..c...",
            ".c...aaaaaaaaaa...c.",
            ".....aaaaaaacaa.....",
            "c....aaaaaacaaa....c",
            ".....aaacacaaaa.....",
            "ddd..aaaacaaaaa..ddd",
            "ddd...aaaaaaaa...ddd",
            "ddd....aaaaaa....ddd",
            "...dddddddddddddd...",
            "...dddddddddddddd...",
            "...dddbddddddbddd...",
            "...ddbdbddddbdbdd...",
            "...dddddeddeddddd...",
            "...ddddddeedddddd...",
            "...dddddddddddddd...",
            "...dddddddddddddd...",
            "...dddddddddddddd...",
            "...d..d......d..d...",
            "..d...d......d...d..",
        ])

}
