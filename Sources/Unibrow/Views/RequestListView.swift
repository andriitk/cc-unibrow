import AppKit
import SwiftUI
import UnibrowCore

/// Scrollable list of pending requests, grouped by project.
struct RequestListView: View {
    let model: AppModel

    @State private var contentHeight: CGFloat = 0
    private static let maxHeight: CGFloat = 460
    private static let fadeHeight: CGFloat = 28

    private var overflows: Bool { contentHeight > Self.maxHeight }

    var body: some View {
        ScrollView(.vertical) {
            // A plain VStack: the list is capped at 100 cards, and lazy stacks
            // mis-measure cards whose text wraps onto several lines.
            VStack(alignment: .leading, spacing: 14) {
                if model.showsWindowFocusHint {
                    WindowFocusHint(
                        onEnable: { model.dismissWindowFocusHint(enable: true) },
                        onDismiss: { model.dismissWindowFocusHint(enable: false) }
                    )
                }
                ForEach(model.queue.groupedByProject, id: \.requests[0].cwd) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        ProjectHeader(name: group.project, count: group.requests.count)
                        ForEach(group.requests) { request in
                            card(for: request)
                                .transition(.asymmetric(
                                    insertion: .opacity.combined(with: .move(edge: .top)),
                                    removal: .opacity.combined(with: .scale(scale: 0.9))
                                ))
                        }
                    }
                }
                if !model.finished.isEmpty {
                    FinishedSection(model: model)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, overflows ? Self.fadeHeight : 12)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollIndicators(.automatic)
        // A ScrollView takes all the height it is offered; size it to its
        // content so the island hugs short lists and scrolls long ones.
        .frame(height: min(max(contentHeight, 1), Self.maxHeight))
        // When the list scrolls, fade its bottom edge so it is obvious there is more.
        .mask {
            VStack(spacing: 0) {
                Rectangle()
                LinearGradient(colors: [.black, overflows ? .clear : .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: Self.fadeHeight)
            }
        }
    }

    @ViewBuilder
    private func card(for request: PendingRequest) -> some View {
        let context = RequestContext(request: request) {
            model.bringToFront(request)
        }
        if request.isQuestion, let questions = UserQuestion.parse(request.toolInput) {
            QuestionCard(
                context: context,
                questions: questions,
                onSubmit: { model.answer(request, with: $0) },
                onSendToTerminal: { model.sendToTerminal(request) }
            )
        } else {
            RequestCard(
                context: context,
                onDecide: { model.decide(request, $0) },
                onSendToTerminal: { model.sendToTerminal(request) }
            )
        }
    }
}

private struct ProjectHeader: View {
    let name: String
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .font(.system(size: 10))
            Text(name)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
            if count > 1 {
                Text("(\(count))")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.45))
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white.opacity(0.55))
        .padding(.horizontal, 4)
    }
}

/// Shown once, after the app chip could only bring an app (not its exact
/// window) to the front.
private struct WindowFocusHint: View {
    let onEnable: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "macwindow.on.rectangle")
                .font(.system(size: 13))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text("Jump to the exact window")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Allow Accessibility once and the app chip opens the session's own window, even with many windows open.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Button("Not Now", action: onDismiss)
                        .buttonStyle(.pill(.quiet))
                    Button("Allow…", action: onEnable)
                        .buttonStyle(.pill(.secondary))
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Sessions that finished their turn. Deliberately quieter than request cards:
/// no buttons to decide, just "done" with a way to jump there.
private struct FinishedSection: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // No check here: the wing and every row already show one.
            HStack(spacing: 6) {
                Text("Finished")
                    .font(.system(size: 11, weight: .semibold))
                Text("nothing to do")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.35))
                Spacer(minLength: 0)
                Button("Clear", action: model.clearFinished)
                    .buttonStyle(.pill(.quiet))
                    .help("Dismiss all finished sessions")
            }
            .foregroundStyle(Color.green.opacity(0.8))
            .padding(.horizontal, 4)

            ForEach(model.finished.items) { notice in
                FinishedRow(
                    notice: notice,
                    onOpen: { model.open(notice) },
                    onDismiss: { model.dismiss(notice) }
                )
                .transition(.opacity)
            }
        }
    }
}

private struct FinishedRow: View {
    let notice: FinishedSession
    let onOpen: () -> Void
    let onDismiss: () -> Void

    @State private var isHovered = false

    private var hostApp: NSRunningApplication? {
        notice.hostPID.flatMap { NSRunningApplication(processIdentifier: $0) }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Color.green.opacity(0.85))
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(notice.projectName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                    if let branch = notice.branch {
                        Chip(text: Chip.shortened(branch), symbol: "arrow.triangle.branch")
                    }
                    Chip(text: notice.sessionTag, symbol: "terminal")
                        .help("Claude Code session \(notice.sessionID)")
                    Spacer(minLength: 4)
                    if let name = hostApp?.localizedName {
                        Button(action: onOpen) {
                            HStack(spacing: 3) {
                                Text(name)
                                Image(systemName: "arrow.up.forward").imageScale(.small)
                            }
                        }
                        .buttonStyle(.pill(.quiet))
                        .help("Open the session in \(name)")
                    }
                    TimelineView(.periodic(from: .now, by: 30)) { timeline in
                        Text(CardHeader.age(from: notice.finishedAt, to: timeline.date))
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }
                if let summary = notice.summary {
                    Text(summary)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(2)
                }
            }

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.pill(.quiet))
            .help("Dismiss")
            .opacity(isHovered ? 1 : 0.4)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.white.opacity(isHovered ? 0.06 : 0.03))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { isHovered = $0 }
    }
}
