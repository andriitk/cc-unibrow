import AppKit
import SwiftUI
import UnibrowCore

/// Sessions that need the user without a request to answer: a turn that
/// stopped on an API error, or a background agent waiting for input. A click
/// opens the session's window.
struct AlertSection: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(model.alerts.items) { alert in
                AlertRow(
                    alert: alert,
                    onOpen: { model.open(alert) },
                    onDismiss: { model.dismiss(alert) }
                )
                .transition(.opacity)
            }
        }
    }
}

private struct AlertRow: View {
    let alert: SessionAlert
    let onOpen: () -> Void
    let onDismiss: () -> Void

    @State private var isHovered = false
    @State private var isShowingDetails = false

    private var hostApp: NSRunningApplication? {
        alert.hostPID.flatMap { NSRunningApplication(processIdentifier: $0) }
    }

    private var tint: Color { alert.isFailure ? Color(red: 1, green: 0.35, blue: 0.32) : .orange }

    private var details: String? {
        if case .stopFailure(_, let details) = alert.kind { details } else { nil }
    }

    /// The failure's hint, or the agent's own message.
    private var subtitle: String? {
        switch alert.kind {
        case .stopFailure(let error, _): error.hint
        case .needsInput(let title, let message):
            [title, message].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: alert.isFailure ? "exclamationmark.octagon.fill" : "person.crop.circle.badge.questionmark")
                .font(.system(size: 13))
                .foregroundStyle(tint)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(alert.projectName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                    if let branch = alert.branch {
                        Chip(text: Chip.shortened(branch), symbol: "arrow.triangle.branch")
                    }
                    Chip(text: alert.sessionTag, symbol: "terminal")
                        .help("Claude Code session \(alert.sessionID)")
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
                        Text(CardHeader.age(from: alert.receivedAt, to: timeline.date))
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }

                Text(alert.headline)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(tint)
                    .fixedSize(horizontal: false, vertical: true)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(isShowingDetails ? nil : 2)
                }

                if let details {
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { isShowingDetails.toggle() }
                    } label: {
                        Label(isShowingDetails ? "Less" : "Details", systemImage: isShowingDetails ? "chevron.up" : "chevron.down")
                            .imageScale(.small)
                    }
                    .buttonStyle(.pill(.quiet))

                    if isShowingDetails {
                        ScrollView(.vertical) {
                            Text(details)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.8))
                                .textSelection(.enabled)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 140)
                        .fixedSize(horizontal: false, vertical: true)
                        .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
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
                .fill(tint.opacity(isHovered ? 0.16 : 0.1))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { isHovered = $0 }
    }
}
