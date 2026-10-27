import AppKit
import Observation
import os
import UnibrowCore

/// The app's single source of truth: pending requests, user settings and the
/// bridge between the socket server and the UI.
@MainActor
@Observable
final class AppModel {
    enum Choice {
        case allow, allowAlways, deny
    }

    private(set) var queue = ApprovalQueue()
    private(set) var serverError: String?
    private(set) var hookStatus: HookLinker.Status = .relayMissing
    private(set) var pluginStatus: ClaudePlugin.Status = .unknown
    private(set) var isInstallingPlugin = false

    /// Sessions that finished their turn: an FYI, nothing waits for the user.
    private(set) var finished = FinishedSessions()

    /// Sessions that need the user without a request to answer: the turn
    /// failed on an API error, or a background agent waits for input.
    private(set) var alerts = SessionAlerts()

    /// What briefly peeks out of the notch: a new request, an alert, or a
    /// session that just finished.
    enum Peek: Equatable {
        case request(PendingRequest)
        case alert(SessionAlert)
        case finished(FinishedSession)
    }

    /// Whether the island has anything to show.
    var hasContent: Bool { !queue.isEmpty || !alerts.isEmpty || !finished.isEmpty }

    private(set) var peek: Peek?

    /// While paused, Unibrow steps aside: every request and elicitation goes
    /// straight to the terminal prompt and nothing shows in the notch, alerts
    /// and finished notices included.
    var isPaused: Bool {
        didSet {
            defaults.set(isPaused, forKey: Keys.paused)
            if isPaused { stepAside() }
        }
    }

    /// Deny also stops Claude's turn, so it waits for your next instruction
    /// instead of trying another approach.
    var denyStopsTurn: Bool {
        didSet { defaults.set(denyStopsTurn, forKey: Keys.denyStopsTurn) }
    }

    var playsSound: Bool {
        didSet { defaults.set(playsSound, forKey: Keys.playsSound) }
    }

    /// Show a quiet "done" notice when a session finishes its turn. Alerts (a
    /// failed turn, an agent waiting for input) are not "done" notices and
    /// show either way: they need the user.
    var showsFinishedSessions: Bool {
        didSet {
            defaults.set(showsFinishedSessions, forKey: Keys.showsFinishedSessions)
            if !showsFinishedSessions { clearFinished() }
        }
    }

    /// Requests older than this are dropped from the notch. Matches the hook
    /// timeout in the plugin, after which Claude Code stops waiting anyway.
    static let maxRequestAge: TimeInterval = 60 * 60

    /// Hard cap on the list. Beyond it requests go to the terminal, so a
    /// runaway agent can never make the app grow without bound.
    static let maxPendingRequests = 100

    private let server: ApprovalServer
    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "dev.andriitk.unibrow", category: "model")
    private var eventsTask: Task<Void, Never>?
    private var sweepTask: Task<Void, Never>?
    private var peekTask: Task<Void, Never>?
    private var accessibilityObserver: (any NSObjectProtocol)?
    private var accessibilityPollTask: Task<Void, Never>?

    private enum Keys {
        static let paused = "paused"
        static let denyStopsTurn = "denyStopsTurn"
        static let playsSound = "playsSound"
        static let windowFocusHintDismissed = "windowFocusHintDismissed"
        static let showsFinishedSessions = "showsFinishedSessions"
    }

    init(server: ApprovalServer = ApprovalServer(), defaults: UserDefaults = .standard) {
        self.server = server
        self.defaults = defaults
        defaults.register(defaults: [
            Keys.denyStopsTurn: true,
            Keys.playsSound: true,
            Keys.showsFinishedSessions: true,
        ])
        isPaused = defaults.bool(forKey: Keys.paused)
        denyStopsTurn = defaults.bool(forKey: Keys.denyStopsTurn)
        playsSound = defaults.bool(forKey: Keys.playsSound)
        showsFinishedSessions = defaults.bool(forKey: Keys.showsFinishedSessions)
    }

    // MARK: - Lifecycle

    func start() {
        hookStatus = HookLinker.link()
        Task { pluginStatus = await ClaudePlugin.status() }
        do {
            try server.start()
        } catch {
            serverError = error.description
            logger.error("Server failed to start: \(error.description, privacy: .public)")
            return
        }

        eventsTask = Task { [weak self, events = server.events] in
            for await event in events {
                self?.handle(event)
            }
        }
        sweepTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                self?.sweepExpired()
            }
        }
        // Safety net in case the system notification below never arrives:
        // the check is a single cheap syscall.
        accessibilityPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                self?.refreshWindowFocus()
            }
        }
        // The system posts this when any app's Accessibility access changes;
        // the notification can arrive slightly before the new state is
        // readable, so re-check shortly after as well.
        accessibilityObserver = DistributedNotificationCenter.default().addObserver(
            forName: WindowFocus.changedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshWindowFocus()
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(1))
                    self?.refreshWindowFocus()
                }
            }
        }
    }

    func stop() {
        if let accessibilityObserver {
            DistributedNotificationCenter.default().removeObserver(accessibilityObserver)
        }
        eventsTask?.cancel()
        sweepTask?.cancel()
        accessibilityPollTask?.cancel()
        server.stop()
    }

    // MARK: - User actions

    func installPlugin() {
        guard !isInstallingPlugin else { return }
        isInstallingPlugin = true
        Task {
            let installed = await ClaudePlugin.install()
            pluginStatus = installed ? .installed : await ClaudePlugin.status()
            isInstallingPlugin = false
        }
    }

    /// Any hook event proves the plugin works, even if the CLI check could not tell.
    private func notePluginWorks() {
        if pluginStatus != .installed { pluginStatus = .installed }
    }

    func decide(_ request: PendingRequest, _ choice: Choice) {
        guard queue.remove(id: request.id) != nil else { return }
        clearPeek(ifShowing: request)

        let decision: Decision = switch choice {
        case .allow: .allow
        case .allowAlways: .allowAlways(updatedPermissions: request.suggestions)
        case .deny where request.isPlanApproval:
            // Rejecting a plan means "keep planning", never "stop".
            .deny(message: "The user wants to keep planning. Ask what to change in the plan.", interrupt: false)
        case .deny: .deny(message: "Denied from Unibrow.", interrupt: denyStopsTurn)
        }
        server.respond(to: request.id, with: decision)
    }

    /// Answers an `AskUserQuestion` request: chosen labels per question text.
    func answer(_ request: PendingRequest, with answers: [String: [String]]) {
        guard queue.remove(id: request.id) != nil else { return }
        clearPeek(ifShowing: request)
        let input = UserQuestion.answeredInput(request.toolInput, answers: answers)
        server.respond(to: request.id, with: .allowWithInput(updatedInput: input))
    }

    /// Answers an MCP elicitation from its card.
    func answerElicitation(_ request: PendingRequest, _ answer: ElicitationAnswer) {
        guard request.elicitation != nil, queue.remove(id: request.id) != nil else { return }
        clearPeek(ifShowing: request)
        server.respond(to: request.id, with: .answerElicitation(answer))
    }

    /// URL mode: opens the link in the browser, then accepts. Claude Code
    /// does not open it itself once a hook accepted.
    func openElicitationLink(_ request: PendingRequest) {
        guard case .url(let link)? = request.elicitation?.content, let url = link.openableURL else { return }
        guard NSWorkspace.shared.open(url) else {
            // Could not open it: let the terminal dialog handle it.
            sendToTerminal(request)
            return
        }
        answerElicitation(request, .accept(content: [:]))
    }

    /// Hands the request back to the terminal prompt.
    func sendToTerminal(_ request: PendingRequest) {
        guard queue.remove(id: request.id) != nil else { return }
        clearPeek(ifShowing: request)
        server.respond(to: request.id, with: .passthrough)
        bringToFront(request)
    }

    /// Opens the session that finished and clears its notice.
    func open(_ notice: FinishedSession) {
        bringToFront(hostPID: notice.hostPID, projectRoot: notice.projectRoot, cwd: notice.cwd)
        dismiss(notice)
    }

    func dismiss(_ notice: FinishedSession) {
        finished.remove(sessionID: notice.sessionID)
        clearPeek(ifShowing: notice)
    }

    /// Opens the session an alert is about and clears the alert.
    func open(_ alert: SessionAlert) {
        bringToFront(hostPID: alert.hostPID, projectRoot: alert.projectRoot, cwd: alert.cwd)
        dismiss(alert)
    }

    func dismiss(_ alert: SessionAlert) {
        alerts.remove(sessionID: alert.sessionID)
        clearPeek(ifShowing: alert)
    }

    /// Hands every waiting request back to the terminal and clears the notch.
    private func stepAside() {
        for request in queue.requests {
            server.respond(to: request.id, with: .passthrough)
            _ = queue.remove(id: request.id)
        }
        clearFinished()
        alerts.removeAll()
        peek = nil
    }

    func clearFinished() {
        finished.removeAll()
        if case .finished = peek { peek = nil }
    }

    func bringToFront(_ request: PendingRequest) {
        bringToFront(hostPID: request.hostPID, projectRoot: request.projectRoot, cwd: request.cwd)
    }

    /// Brings the terminal or IDE that runs the session to the front, trying
    /// the most precise way first:
    /// 1. Accessibility (if granted): the exact window, in any app.
    /// 2. Editors (Cursor, VS Code, JetBrains…): open the repository root,
    ///    which makes the editor switch to that project's window. No
    ///    permission needed; also covers windows on another Space.
    /// 3. Otherwise the app with its last-used window.
    private func bringToFront(hostPID: Int32?, projectRoot: String?, cwd: String) {
        guard let pid = hostPID, let app = NSRunningApplication(processIdentifier: pid) else { return }
        if WindowFocus.raiseWindow(of: app, projectPath: projectRoot ?? cwd) { return }
        if let projectRoot, EditorFocus.focus(folder: projectRoot, in: app) { return }

        app.activate()
        // Only the least precise path got here: offer the precise one, once.
        if !windowFocusEnabled, !windowFocusHintDismissed {
            showsWindowFocusHint = true
        }
    }

    /// Whether Accessibility access is granted, kept current: the permission
    /// is changed in System Settings, outside the app.
    private(set) var windowFocusEnabled = WindowFocus.isEnabled

    /// Turns exact window focus on (system prompt) or sends the user to
    /// System Settings to turn it off.
    func toggleWindowFocus() {
        if windowFocusEnabled {
            WindowFocus.openSettings()
        } else {
            WindowFocus.requestAccess()
            WindowFocus.openSettings()
        }
    }

    private func refreshWindowFocus() {
        let enabled = WindowFocus.isEnabled
        if enabled != windowFocusEnabled { windowFocusEnabled = enabled }
        if enabled { showsWindowFocusHint = false }
    }

    /// One-time tip in the notch: with Accessibility access, the app chip
    /// raises the exact window instead of the app's last-used one.
    private(set) var showsWindowFocusHint = false

    private var windowFocusHintDismissed: Bool {
        get { defaults.bool(forKey: Keys.windowFocusHintDismissed) }
        set { defaults.set(newValue, forKey: Keys.windowFocusHintDismissed) }
    }

    func dismissWindowFocusHint(enable: Bool) {
        showsWindowFocusHint = false
        windowFocusHintDismissed = true
        if enable { WindowFocus.requestAccess() }
    }

    // MARK: - Server events

    private func handle(_ event: ApprovalServer.Event) {
        switch event {
        case .message(let id, let message, let peerPID):
            notePluginWorks()
            let payload = HookPayload(raw: message.payload)
            if let sessionID = payload.sessionID {
                // Any sign of life in a session retires its "finished" notice.
                if let notice = finished.items.first(where: { $0.sessionID == sessionID }) {
                    finished.handle(message.event, sessionID: sessionID)
                    if finished.items.first(where: { $0.sessionID == sessionID }) == nil {
                        clearPeek(ifShowing: notice)
                    }
                }
                // The session moved on: its alert is stale.
                if let alert = alerts.handle(message.event, sessionID: sessionID) {
                    clearPeek(ifShowing: alert)
                }
            }
            if message.event == .stop {
                recordFinished(payload, message: message, hookPID: peerPID)
            }
            if let alert = SessionAlert(event: message.event, payload: payload) {
                recordAlert(alert, message: message, hookPID: peerPID)
            }
            if message.event.expectsDecision {
                enqueue(payload, message: message, connection: id, hookPID: peerPID)
            } else {
                for request in queue.resolve(after: message.event, payload: payload) {
                    server.drop(request.id)
                    clearPeek(ifShowing: request)
                }
            }

        case .closed(let id):
            if let request = queue.remove(id: id) {
                clearPeek(ifShowing: request)
            }
        }
    }

    private func enqueue(
        _ payload: HookPayload,
        message: HookMessage,
        connection id: ApprovalServer.ConnectionID,
        hookPID: pid_t?
    ) {
        let parsed = message.event == .elicitation
            ? PendingRequest(elicitationPayload: payload, propertyOrder: message.propertyOrder, id: id)
            : PendingRequest(payload: payload, id: id)
        guard !isPaused,
              queue.count < Self.maxPendingRequests,
              var request = parsed
        else {
            server.respond(to: id, with: .passthrough)
            return
        }
        request.branch = message.branch
        request.projectRoot = message.projectRoot
        queue.append(request)
        if playsSound { NSSound(named: "Tink")?.play() }
        showPeek(.request(request))
        if let deadline = request.answerDeadline {
            // The relay gives up at the deadline and closes the socket, which
            // drops the card; this catches a relay that did not.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow) + 2))
                guard let self, self.queue.remove(id: request.id) != nil else { return }
                self.server.drop(request.id)
                self.clearPeek(ifShowing: request)
            }
        }
        Task {
            guard let app = await Self.hostApp(for: message, hookPID: hookPID) else { return }
            queue.update(id: request.id) { $0.hostPID = app.processIdentifier }
        }
    }

    private func recordFinished(_ payload: HookPayload, message: HookMessage, hookPID: pid_t?) {
        guard !isPaused, showsFinishedSessions, var notice = FinishedSession(stopPayload: payload) else { return }
        notice.branch = message.branch
        notice.projectRoot = message.projectRoot
        Task {
            let app = await Self.hostApp(for: message, hookPID: hookPID)
            notice.hostPID = app?.processIdentifier
            // Paused while the host app was being looked up.
            guard !isPaused else { return }
            finished.record(notice)
            // No peek if you are already looking at that session's app: you
            // can see it is done. No sound either way; this is just an FYI.
            if app?.isActive != true {
                showPeek(.finished(notice))
            }
        }
    }

    private func recordAlert(_ alert: SessionAlert, message: HookMessage, hookPID: pid_t?) {
        guard !isPaused else { return }
        var alert = alert
        alert.branch = message.branch
        alert.projectRoot = message.projectRoot
        Task {
            let app = await Self.hostApp(for: message, hookPID: hookPID)
            alert.hostPID = app?.processIdentifier
            // Paused, or the session moved on, while the host app was looked up.
            guard !isPaused, !queue.requests.contains(where: { $0.sessionID == alert.sessionID }) else { return }
            alerts.record(alert)
            if playsSound { NSSound(named: "Tink")?.play() }
            showPeek(.alert(alert))
        }
    }

    /// The terminal or IDE a hook runs in. Prefers the ancestor chain the
    /// hook sent; otherwise walks from the hook process, off the main thread
    /// because it may ask tmux.
    private static func hostApp(for message: HookMessage, hookPID: pid_t?) async -> NSRunningApplication? {
        if let ancestors = message.ancestorPIDs, !ancestors.isEmpty {
            return HostApp.firstRegularApp(in: ancestors)
        }
        guard let hookPID else { return nil }
        let candidates = await Task.detached(priority: .utility) {
            ProcessAncestry.candidates(of: hookPID)
        }.value
        return HostApp.firstRegularApp(in: candidates)
    }

    private func sweepExpired() {
        finished.removeExpired(now: .now)
        if case .finished(let notice) = peek, !finished.items.contains(notice) { peek = nil }
        alerts.removeExpired(now: .now)
        if case .alert(let alert) = peek, !alerts.items.contains(alert) { peek = nil }
        for request in queue.removeExpired(now: .now, maxAge: Self.maxRequestAge) {
            server.drop(request.id)
            clearPeek(ifShowing: request)
        }
    }

    // MARK: - Peek

    private func showPeek(_ newPeek: Peek) {
        // A finished notice never covers a request or an alert that is still
        // peeking, and an alert never covers a request.
        switch (newPeek, peek) {
        case (.finished, .request?), (.finished, .alert?), (.alert, .request?): return
        default: break
        }
        peek = newPeek
        peekTask?.cancel()
        peekTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.peek = nil
        }
    }

    private func clearPeek(ifShowing request: PendingRequest) {
        if case .request(let shown) = peek, shown.id == request.id { peek = nil }
    }

    private func clearPeek(ifShowing alert: SessionAlert) {
        if case .alert(let shown) = peek, shown.sessionID == alert.sessionID { peek = nil }
    }

    private func clearPeek(ifShowing notice: FinishedSession) {
        if case .finished(let shown) = peek, shown.sessionID == notice.sessionID { peek = nil }
    }
}
