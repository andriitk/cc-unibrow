public import SwiftUI
public import UnibrowCore

/// The drawings on the notch's left side: the left wing and every row's
/// leading mark. Unibrow draws the Claude Code glyph everywhere
/// (`claudeCodeGlyph`, the default). An app that embeds the notch view may
/// draw its own through `\.notchArtwork`; each slot carries the data the row
/// shows (neutral values, no art), so it can vary the drawing per kind of row.
/// The right wing always shows the `NotchIndicator`.
public struct NotchArtwork {
    /// Where the drawing goes, with what that place shows.
    public enum Slot: Equatable, Sendable {
        /// The left wing; `expanded` while the list is open.
        case wing(NotchIndicator, expanded: Bool)
        /// A request, question or MCP card, and its peek row: the request
        /// says which kind (`isQuestion`, `isPlanApproval`, `elicitation`, the tool).
        case request(PendingRequest)
        /// A background agent that waits for input (`kind` `.needsInput`).
        case needsInput(SessionAlert)
        /// A session that stopped on a failure (`kind` `.stopFailure`, with
        /// its `StopFailureKind`).
        case failure(SessionAlert)
        /// A finished session (`kind` `.finished`).
        case finished(FinishedSession)
        /// A session that replied while background work goes on (`kind`
        /// `.update`, with its `BackgroundWork`).
        case update(FinishedSession)

        /// The slot of an alert's row.
        public init(_ alert: SessionAlert) {
            self = alert.isFailure ? .failure(alert) : .needsInput(alert)
        }

        /// The slot of a finished or update row.
        public init(_ notice: FinishedSession) {
            self = notice.isUpdate ? .update(notice) : .finished(notice)
        }
    }

    /// Width of each wing beside the camera housing.
    public let wingWidth: CGFloat
    /// Width every row's drawing gets, so the rows' text lines up.
    public let rowWidth: CGFloat
    let draw: @MainActor (Slot) -> AnyView

    public init(wingWidth: CGFloat, rowWidth: CGFloat, draw: @escaping @MainActor (Slot) -> AnyView) {
        self.wingWidth = wingWidth
        self.rowWidth = rowWidth
        self.draw = draw
    }

    /// Unibrow's own drawing: the Claude Code glyph on the left wing and on
    /// every row.
    public static var claudeCodeGlyph: NotchArtwork {
        NotchArtwork(wingWidth: 46, rowWidth: 22) { _ in AnyView(ClaudeCodeGlyph(cell: 1.5)) }
    }
}

extension EnvironmentValues {
    /// The drawings on the notch's left side; Unibrow's is the Claude Code glyph.
    @Entry public var notchArtwork: NotchArtwork = .claudeCodeGlyph
}

/// What the right wing shows, by priority: red `!` while a session failed
/// (never hidden by a count), orange with the count while something waits,
/// green `✓` while a session finished, calm blue while sessions only replied
/// and background work goes on.
public enum NotchIndicator: Equatable, Sendable {
    case waiting(count: Int)
    case failure
    case done
    case update
}

extension NotchHost {
    /// The right wing's state; `nil` when the island is empty.
    public var indicator: NotchIndicator? {
        if hasFailure { return .failure }
        let waiting = queue.count + alerts.count
        if waiting > 0 { return .waiting(count: waiting) }
        if !finished.finishedItems.isEmpty { return .done }
        return finished.isEmpty ? nil : .update
    }
}

/// A row's leading mark: the artwork's drawing for `slot`.
struct RowMark: View {
    let slot: NotchArtwork.Slot
    @Environment(\.notchArtwork) private var artwork

    var body: some View {
        artwork.draw(slot).frame(width: artwork.rowWidth).accessibilityHidden(true)
    }
}

/// The tool's symbol as the first chip under a card's title, orange.
struct ToolChip: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.orange)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.orange.opacity(0.16), in: Capsule())
            .overlay(Capsule().strokeBorder(.orange.opacity(0.28), lineWidth: 0.5))
            .accessibilityHidden(true)
    }
}
