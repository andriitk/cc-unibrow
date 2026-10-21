import AppKit
import SwiftUI

struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        let icon = Image(nsImage: MenuBarIcon.image(model.isPaused ? .paused : .watching))
        if model.queue.isEmpty {
            icon
                .accessibilityLabel(model.isPaused ? "Unibrow, paused" : "Unibrow")
        } else {
            HStack(spacing: 3) {
                icon
                Text("\(model.queue.count)")
                    .monospacedDigit()
            }
            .accessibilityLabel("Unibrow, \(model.queue.count) pending")
        }
    }
}

struct MenuContent: View {
    @Bindable var model: AppModel
    @State private var launchAtLogin = LoginItem.isEnabled

    var body: some View {
        Text(statusLine)

        if let error = model.serverError {
            Text("⚠︎ \(error)")
        }
        if let hookProblem {
            Text("⚠︎ \(hookProblem)")
        }
        switch model.pluginStatus {
        case .notInstalled:
            Text("⚠︎ The Claude Code plugin is not installed")
            Button(model.isInstallingPlugin ? "Installing Plugin…" : "Install Claude Code Plugin") {
                model.installPlugin()
            }
            .disabled(model.isInstallingPlugin)
        case .claudeMissing:
            Text("⚠︎ Claude Code (the claude command) was not found")
        case .installed, .unknown:
            EmptyView()
        }

        Divider()

        Toggle("Pause (ask in Terminal)", isOn: $model.isPaused)
        Toggle("Deny Stops the Turn", isOn: $model.denyStopsTurn)
        Toggle("Play Sound", isOn: $model.playsSound)
        Toggle("Show Finished Sessions", isOn: $model.showsFinishedSessions)
            .help("A quiet green notice when Claude finishes a turn. Nothing to approve.")
        Toggle("Launch at Login", isOn: Binding(get: { launchAtLogin }, set: { enabled in
            LoginItem.setEnabled(enabled)
            launchAtLogin = LoginItem.isEnabled
        }))

        Divider()

        // A toggle like the others. The permission itself lives in System
        // Settings, so both directions open it; the checkmark follows the
        // real system state.
        Toggle("Exact Window Focus", isOn: Binding(
            get: { model.windowFocusEnabled },
            set: { _ in model.toggleWindowFocus() }
        ))
        .help("Raise the session's own window, not just its app. Needs Accessibility access.")

        Divider()

        // Which build is running, so you can tell whether an update arrived.
        if let version = Self.appVersion {
            Text("Unibrow \(version)")
        }
        Button("Copy Install Command") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(Self.installCommand, forType: .string)
        }
        Button("Quit Unibrow") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// Nil when running unbundled (`swift run`), which has no Info.plist version.
    static let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

    static let installCommand = "curl -fsSL https://raw.githubusercontent.com/andriitk/cc-unibrow/main/install.sh | sh"

    private var statusLine: String {
        if model.isPaused { return "Paused" }
        switch model.queue.count {
        case 0: return "No pending approvals"
        case 1: return "1 pending approval"
        case let count: return "\(count) pending approvals"
        }
    }

    private var hookProblem: String? {
        switch model.hookStatus {
        case .linked: nil
        case .relayMissing: "Hook relay not found next to the app"
        case .failed(let reason): "Cannot link hook relay: \(reason)"
        }
    }
}
