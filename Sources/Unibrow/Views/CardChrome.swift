import AppKit
import SwiftUI
import UnibrowCore

/// What every card needs to know about its request besides the tool itself.
struct RequestContext {
    let request: PendingRequest
    let bringToFront: () -> Void

    var hostApp: NSRunningApplication? {
        request.hostPID.flatMap { NSRunningApplication(processIdentifier: $0) }
    }

    /// "Cursor", "iTerm2", "PyCharm"… or a generic fallback.
    var hostAppName: String {
        hostApp?.localizedName ?? "Terminal"
    }
}

/// Shared card header: tool, branch, session, host app and age.
struct CardHeader: View {
    let context: RequestContext
    let symbol: String
    let title: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.orange)
                .frame(width: 16)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .layoutPriority(1)

            if let branch = context.request.branch {
                Chip(text: Chip.shortened(branch), symbol: "arrow.triangle.branch")
                    .help("Git branch \(branch)")
            }
            if let agent = context.request.agentType {
                Chip(text: Chip.shortened(agent), symbol: "person.2")
                    .help("Asked by the subagent \(agent)")
            }
            // The start of the Claude Code session ID: the same on every card
            // that comes from one terminal, different across terminals.
            Chip(text: context.request.sessionTag, symbol: "terminal")
                .help("Claude Code session \(context.request.sessionID)")

            Spacer(minLength: 6)

            if let app = context.hostApp, let name = app.localizedName {
                Button(action: context.bringToFront) {
                    HStack(spacing: 3) {
                        Text(name)
                        Image(systemName: "arrow.up.forward")
                            .imageScale(.small)
                    }
                }
                .buttonStyle(.pill(.quiet))
                .help("Show \(name)")
            }

            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                Text(Self.age(from: context.request.receivedAt, to: timeline.date))
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
    }

    /// `now`, `12s`, `3m`, `1h`.
    static func age(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        switch seconds {
        case ..<3: return "now"
        case ..<60: return "\(seconds)s"
        case ..<3600: return "\(seconds / 60)m"
        default: return "\(seconds / 3600)h"
        }
    }
}

struct Chip: View {
    let text: String
    let symbol: String?
    var color: Color = .white.opacity(0.55)

    var body: some View {
        HStack(spacing: 3) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 8, weight: .semibold))
            }
            Text(text)
                .lineLimit(1)
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.white.opacity(0.08), in: Capsule())
        .fixedSize()
    }

    /// Keeps chips compact: `feature/payment-retries` → `feature/p…nt-retries`.
    static func shortened(_ text: String, limit: Int = 20) -> String {
        guard text.count > limit else { return text }
        let head = (limit - 1) / 2
        return "\(text.prefix(head))…\(text.suffix(limit - 1 - head))"
    }
}

/// The rounded container every card sits in.
struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(12)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.white.opacity(0.06))
            )
    }
}

extension View {
    func cardBackground() -> some View { modifier(CardBackground()) }
}
