import SwiftUI
import UnibrowCore

/// Coordinate space of the panel canvas, used to report the island frame.
private let canvasSpace = "unibrow.canvas"

/// The whole island: grows out of the notch, shows a pending count, peeks at
/// new requests and expands into the request list on hover.
struct NotchRootView: View {
    let model: AppModel
    let island: IslandState

    private enum Mode: Equatable {
        case hidden, compact, peek, expanded
    }

    private enum Metrics {
        static let wing: CGFloat = 46
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

    /// Something needs the user (orange), or only "done" notices are left (green).
    private var needsAttention: Bool { !model.queue.isEmpty || !model.alerts.isEmpty }

    private var width: CGFloat {
        let notch = island.notchSize.width
        switch mode {
        case .hidden: return notch
        case .compact: return notch + 2 * Metrics.wing
        case .peek: return max(notch + 2 * Metrics.wing, Metrics.peekWidth)
        case .expanded: return max(notch + 2 * Metrics.wing, Metrics.expandedWidth)
        }
    }

    var body: some View {
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
                if needsAttention {
                    PulsingDot()
                } else {
                    DoneMark()
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
                if needsAttention {
                    CountBadge(count: model.queue.count + model.alerts.count)
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
            Image(systemName: ElicitationCard.symbol(for: elicitation))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.orange)
                .frame(width: 18)
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

/// A calm green check: something finished, nothing to do.
private struct DoneMark: View {
    var body: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.green)
            .accessibilityLabel("A session finished")
    }
}

private struct FinishedPeekRow: View {
    let notice: FinishedSession

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.green)
                .frame(width: 18)
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

private struct PulsingDot: View {
    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(Color.orange)
            .frame(width: 8, height: 8)
            .overlay(
                Circle()
                    .stroke(Color.orange.opacity(0.6), lineWidth: 2)
                    .scaleEffect(isPulsing ? 2.2 : 1)
                    .opacity(isPulsing ? 0 : 1)
            )
            .onAppear {
                withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                    isPulsing = true
                }
            }
            .accessibilityHidden(true)
    }
}

private struct CountBadge: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.black)
            .padding(.horizontal, 7)
            .frame(minWidth: 20, minHeight: 18)
            .background(Color.orange, in: Capsule())
            .contentTransition(.numericText())
            .accessibilityLabel("\(count) items need you")
    }
}

private struct AlertPeekRow: View {
    let alert: SessionAlert

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: alert.isFailure ? "exclamationmark.octagon.fill" : "person.crop.circle.badge.questionmark")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(alert.isFailure ? Color.red : Color.orange)
                .frame(width: 18)
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
            Image(systemName: summary.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.orange)
                .frame(width: 18)
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
