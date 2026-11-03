public import Observation
public import UnibrowCore

/// What the notch views read and ask for. The app that shows the notch
/// implements it; the views never see anything else of that app.
///
/// State is plain core values, so the views draw whatever the host holds.
/// Actions say what the user chose; the host decides what that means (the
/// decision sent to Claude Code, where focus goes, what is remembered).
/// The views update through Observation, so a conforming type must be
/// `@Observable`.
@MainActor
public protocol NotchHost: AnyObject, Observable {
    /// Requests waiting for an answer.
    var queue: ApprovalQueue { get }
    /// Sessions that need the user without a request to answer.
    var alerts: SessionAlerts { get }
    /// Sessions that finished their turn.
    var finished: FinishedSessions { get }
    /// Subagents running per session, shown as a count next to the session.
    var subagents: RunningSubagents { get }
    /// What briefly peeks out of the closed island, if anything.
    var peek: NotchPeek? { get }
    /// Whether the list starts with the one-time "jump to the exact window" tip.
    var showsWindowFocusHint: Bool { get }

    /// A permission card was answered.
    func decide(_ request: PendingRequest, _ choice: PermissionChoice)
    /// An `AskUserQuestion` card was submitted: chosen labels per question text.
    func answer(_ request: PendingRequest, with answers: [String: [String]])
    /// An MCP elicitation card was answered (Submit, Decline or Cancel).
    func answerElicitation(_ request: PendingRequest, _ answer: ElicitationAnswer)
    /// Open on a URL elicitation.
    func openElicitationLink(_ request: PendingRequest)
    /// "Answer in Terminal": hand the request back to Claude Code's own prompt.
    func sendToTerminal(_ request: PendingRequest)
    /// The host-app chip on a card, or focus handed back after typing an answer.
    func bringToFront(_ request: PendingRequest)

    func open(_ alert: SessionAlert)
    func dismiss(_ alert: SessionAlert)
    func open(_ notice: FinishedSession)
    func dismiss(_ notice: FinishedSession)
    func clearFinished()

    /// The tip's buttons: Allow… (`true`) or Not Now (`false`).
    func dismissWindowFocusHint(enable: Bool)
}

extension NotchHost {
    /// Whether the island has anything to show.
    public var hasContent: Bool { !queue.isEmpty || !alerts.isEmpty || !finished.isEmpty }
}

/// What briefly peeks out of the notch: a new request, an alert, or a
/// session that just finished.
public enum NotchPeek: Equatable, Sendable {
    case request(PendingRequest)
    case alert(SessionAlert)
    case finished(FinishedSession)
}

/// The answers on a permission card.
public enum PermissionChoice: Equatable, Sendable {
    case allow, allowAlways, deny
}
