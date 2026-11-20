public import SwiftUI
import UnibrowCore

/// Coordinate space of the panel canvas, used to report the island frame.
private let canvasSpace = "unibrow.canvas"

/// The whole island: grows out of the notch, shows a pending count, peeks at
/// new requests and expands into the request list on hover.
///
/// The host puts it in a panel at the top of the screen, keeps `island`
/// current (notch size, hover) and sets `\.beginTyping` so text fields can
/// take the keyboard.
public struct NotchRootView: View {
    let model: any NotchHost
    let island: IslandState

    public init(model: any NotchHost, island: IslandState) {
        self.model = model
        self.island = island
    }

    private enum Mode: Equatable {
        case hidden, compact, peek, expanded
    }

    private enum Metrics {
        /// Wide enough for Claude's drawing (30 cells × 1.5 pt) beside the camera housing.
        static let wing: CGFloat = 64
        /// One cell of the left drawing: 3 px on a @2x screen, so the edges stay sharp.
        static let artCell: CGFloat = 1.5
        static let shoulder: CGFloat = 6
        static let peekWidth: CGFloat = 380
        static let expandedWidth: CGFloat = 500
    }

    private var mode: Mode {
        if !model.hasContent { return .hidden }
        if island.isExpanded { return .expanded }
        if model.peek != nil { return .peek }
        return .compact
    }

    private var width: CGFloat {
        let notch = island.notchSize.width
        switch mode {
        case .hidden: return notch
        case .compact: return notch + 2 * Metrics.wing
        case .peek: return max(notch + 2 * Metrics.wing, Metrics.peekWidth)
        case .expanded: return max(notch + 2 * Metrics.wing, Metrics.expandedWidth)
        }
    }

    public var body: some View {
        island(content)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .coordinateSpace(.named(canvasSpace))
            .environment(\.colorScheme, .dark)
            .animation(.spring(response: 0.38, dampingFraction: 0.8), value: mode)
            .animation(.spring(response: 0.32, dampingFraction: 0.85), value: model.queue.count)
            .animation(.spring(response: 0.32, dampingFraction: 0.85), value: model.finished.count)
            .animation(.spring(response: 0.32, dampingFraction: 0.85), value: model.alerts.count)
    }


    private func island(_ content: some View) -> some View {
        let shoulder = Metrics.shoulder
        let radius: CGFloat = mode == .expanded ? 22 : (mode == .peek ? 18 : island.notchSize.height / 2.4)

        return content
            .frame(width: width - 2 * shoulder)
            .padding(.horizontal, shoulder)
            .background(.black, in: IslandShape(shoulderRadius: shoulder, bottomRadius: radius))
            .clipShape(IslandShape(shoulderRadius: shoulder, bottomRadius: radius))
            .shadow(color: .black.opacity(mode == .expanded ? 0.45 : 0), radius: 18, y: 8)
            .opacity(mode == .hidden ? 0 : 1)
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named(canvasSpace))
            } action: { frame in
                island.islandFrame = frame
            }
            .onChange(of: mode == .hidden) { _, hidden in
                if hidden { island.isExpanded = false }
            }
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            wings
                .frame(height: island.notchSize.height)

            switch mode {
            case .peek:
                Group {
                    switch model.peek {
                    case .request(let request):
                        PeekRow(request: request)
                    case .alert(let alert):
                        AlertPeekRow(alert: alert)
                    case .finished(let notice):
                        FinishedPeekRow(notice: notice)
                    case nil:
                        EmptyView()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            case .expanded:
                RequestListView(model: model)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            case .hidden, .compact:
                EmptyView()
            }
        }
    }

    /// The strips left and right of the camera housing.
    private var wings: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                if let indicator = model.indicator {
                    // Open, the list's rows carry the same drawings; the header's one steps down so it clears the
                    // screen's top edge.
                    ClaudeStateArt(indicator.claudeState, cell: mode == .expanded ? 1 : Metrics.artCell)
                }
                if mode == .expanded {
                    Text("Claude Code")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 12)

            Spacer(minLength: island.notchSize.width)

            Group {
                if let indicator = model.indicator {
                    IndicatorBadge(indicator: indicator)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 12)
        }
    }
}

// MARK: - Pieces

private struct ElicitationPeekRow: View {
    let request: PendingRequest
    let elicitation: ElicitationRequest

    var body: some View {
        HStack(spacing: 10) {
            ClaudeStateMark(state: .needsYou)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(request.projectName) · \(elicitation.serverName)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                Text(elicitation.message.isEmpty ? "An MCP server asks for input" : elicitation.message)
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct FinishedPeekRow: View {
    let notice: FinishedSession

    var body: some View {
        HStack(spacing: 10) {
            ClaudeStateMark(state: .done)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(notice.projectName) · Done")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                Text(notice.summary ?? "Claude finished and is waiting for you")
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
    }
}

extension NotchIndicator {
    /// Claude's pose on the left wing for this state.
    var claudeState: ClaudeState {
        switch self {
        case .waiting: .needsYou
        case .failure: .failure
        case .done: .done
        }
    }
}

/// The right wing: a capsule with the count, ✓ or !, in the state's colour.
private struct IndicatorBadge: View {
    let indicator: NotchIndicator

    var body: some View {
        label
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.black)
            .padding(.horizontal, 7)
            .frame(minWidth: 20, minHeight: 18)
            .background(tint, in: Capsule())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibility)
    }

    @ViewBuilder private var label: some View {
        switch indicator {
        case .waiting(let count): Text("\(count)").contentTransition(.numericText())
        case .failure: Text("!")
        case .done: Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy))
        }
    }

    private var tint: Color {
        switch indicator {
        case .waiting: .orange
        // The red of a failed session's card (`AlertSection`).
        case .failure: Color(red: 1, green: 0.35, blue: 0.32)
        case .done: .green
        }
    }

    private var accessibility: String {
        switch indicator {
        case .waiting(let count): count == 1 ? "1 item needs you" : "\(count) items need you"
        case .failure: "A session failed"
        case .done: "A session finished"
        }
    }
}

private struct AlertPeekRow: View {
    let alert: SessionAlert

    var body: some View {
        HStack(spacing: 10) {
            ClaudeStateMark(state: alert.isFailure ? .failure : .needsYou)
            VStack(alignment: .leading, spacing: 2) {
                Text(alert.projectName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                Text(alert.headline)
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct PeekRow: View {
    let request: PendingRequest

    var body: some View {
        if let elicitation = request.elicitation {
            ElicitationPeekRow(request: request, elicitation: elicitation)
        } else {
            toolRow
        }
    }

    @ViewBuilder
    private var toolRow: some View {
        let summary = ToolSummary(toolName: request.toolName, input: request.toolInput, cwd: request.cwd)
        HStack(spacing: 10) {
            ClaudeStateMark(state: .needsYou)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(request.projectName) · \(summary.title)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                Text(summary.headline)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
    }
}
