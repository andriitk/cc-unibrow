public import SwiftUI

/// What an app that embeds the notch view may draw in place of the notch's own
/// marks, through `\.notchArtwork`. Unibrow itself sets none, so the notch
/// keeps its pulsing dot, count and symbols.
public struct NotchArtwork {
    /// Where the drawing goes.
    public enum Slot: Equatable, Sendable {
        /// The left wing; `expanded` while the request list is open.
        case wing(NotchIndicator, expanded: Bool)
        /// A request, question or MCP card, and its peek row.
        case request
        /// A background agent that waits for input.
        case needsInput
        /// A session that stopped on a failure.
        case failure
        /// A finished session.
        case finished
    }

    /// Width of each wing beside the camera housing while artwork is shown.
    public let wingWidth: CGFloat
    /// Width every row's drawing gets, so the rows' text lines up.
    public let rowWidth: CGFloat
    let draw: @MainActor (Slot) -> AnyView

    public init(wingWidth: CGFloat, rowWidth: CGFloat, draw: @escaping @MainActor (Slot) -> AnyView) {
        self.wingWidth = wingWidth
        self.rowWidth = rowWidth
        self.draw = draw
    }
}

extension EnvironmentValues {
    /// The host's drawings for the notch; `nil` keeps the notch's own marks.
    @Entry public var notchArtwork: NotchArtwork? = nil
}

/// What the right wing shows while a host draws the left one: red when a
/// session failed (never hidden by a count), orange with the count while
/// something waits, green when only finished sessions are left.
public enum NotchIndicator: Equatable, Sendable {
    case waiting(count: Int)
    case failure
    case done
}

extension NotchHost {
    /// The right wing's state; `nil` when the island is empty.
    public var indicator: NotchIndicator? {
        if hasFailure { return .failure }
        let waiting = queue.count + alerts.count
        if waiting > 0 { return .waiting(count: waiting) }
        return finished.isEmpty ? nil : .done
    }
}

/// A row's leading mark: the host's drawing for `slot` when it set one, else
/// the notch's own symbol.
struct RowMark<Fallback: View>: View {
    let slot: NotchArtwork.Slot
    @ViewBuilder let fallback: () -> Fallback
    @Environment(\.notchArtwork) private var artwork

    var body: some View {
        if let artwork {
            artwork.draw(slot).frame(width: artwork.rowWidth).accessibilityHidden(true)
        } else {
            fallback()
        }
    }
}

/// The tool's symbol in a small tinted tile, shown after the host's drawing.
struct ToolTile: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.orange)
            .frame(width: 20, height: 20)
            .background(.orange.opacity(0.16), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(.orange.opacity(0.28), lineWidth: 0.5))
            .accessibilityHidden(true)
    }
}
