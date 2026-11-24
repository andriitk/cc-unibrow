import SwiftUI
import UnibrowCore

/// The first line of an alert or finished row: project, chips, the button
/// that opens the session's app, and the age.
///
/// It never wraps or breaks a word. When the line is too narrow it drops
/// detail in a fixed order, so the project name stays readable as long as
/// possible: first the branch chip, then the app's name on the button (the
/// arrow stays, the name moves to the tooltip). Only the last layout lets
/// the project name truncate.
struct SessionPlaceRow: View {
    let projectName: String
    let branch: String?
    let sessionTag: String
    let sessionID: String
    let agents: RunningSubagents.Badge?
    /// The app the session runs in; `nil` hides the button.
    let hostAppName: String?
    let since: Date
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            ViewThatFits(in: .horizontal) {
                line(showsBranch: true, namesApp: true, truncatesProject: false)
                line(showsBranch: false, namesApp: true, truncatesProject: false)
                line(showsBranch: false, namesApp: false, truncatesProject: false)
                line(showsBranch: false, namesApp: false, truncatesProject: true)
            }
            TimelineView(.periodic(from: .now, by: 30)) { timeline in
                Text(CardHeader.age(from: since, to: timeline.date))
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.4))
                    .fixedSize()
            }
        }
    }

    private func line(showsBranch: Bool, namesApp: Bool, truncatesProject: Bool) -> some View {
        HStack(spacing: 6) {
            Text(projectName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .fixedSize(horizontal: !truncatesProject, vertical: false)
            if showsBranch, let branch {
                Chip(text: Chip.shortened(branch), symbol: "arrow.triangle.branch")
                    .help("Git branch \(branch)")
            }
            Chip(text: sessionTag, symbol: "terminal")
                .help("Claude Code session \(sessionID)")
            if let agents {
                Chip(text: agents.text, symbol: "person.3")
                    .help(agents.help)
            }
            Spacer(minLength: 4)
            if let hostAppName {
                Button(action: onOpen) {
                    HStack(spacing: 3) {
                        if namesApp { Text(hostAppName) }
                        Image(systemName: "arrow.up.forward").imageScale(.small)
                    }
                }
                .buttonStyle(.pill(.quiet))
                .help("Open the session in \(hostAppName)")
                .accessibilityLabel("Open the session in \(hostAppName)")
            }
        }
    }
}
