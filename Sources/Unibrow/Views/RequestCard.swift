import AppKit
import SwiftUI
import UnibrowCore

/// One pending permission request: what Claude wants to do, and the answers.
struct RequestCard: View {
    let context: RequestContext
    let onDecide: (AppModel.Choice) -> Void
    let onSendToTerminal: () -> Void

    @State private var isShowingDetail = false
    /// The request whose detail the user opened. Allow waits for it whenever
    /// the headline alone does not show the whole input. An ID, not a flag,
    /// so a review never carries over if SwiftUI reuses this view for
    /// another request.
    @State private var reviewedRequestID: PendingRequest.ID?

    private var request: PendingRequest { context.request }

    var body: some View {
        let summary = ToolSummary(toolName: request.toolName, input: request.toolInput, cwd: request.cwd)
        let review = summary.review
        VStack(alignment: .leading, spacing: 8) {
            CardHeader(context: context, symbol: summary.symbol, title: summary.title)

            // An input that fits is never cut; anything longer is reviewed in
            // the detail, so the headline may stay a two-line label.
            Text(summary.headline.isEmpty ? "—" : summary.headline)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.white)
                .lineLimit(isShowingDetail || review.fitsInHeadline ? nil : 2)
                .truncationMode(.middle)
                .textSelection(.enabled)

            if let caption = summary.caption, !caption.isEmpty {
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(2)
            }

            if Self.hasNotes(review) {
                ReviewNotes(review: review)
            }

            if isShowingDetail, let detail = summary.detail {
                DetailView(detail: detail)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if !review.canApproveHere {
                TooLongNote(hostAppName: context.hostAppName, onSendToTerminal: onSendToTerminal)
            }

            actions(summary: summary)
        }
        .cardBackground()
        .contextMenu {
            Button("Answer in \(context.hostAppName)", systemImage: "arrow.up.forward.app", action: onSendToTerminal)
            Button("Copy Details", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(request.toolInput.prettyString, forType: .string)
            }
        }
    }

    /// Allow needs the whole input on screen: it fits in the headline, or the
    /// user opened this request's detail, and nothing was cut from it. Deny
    /// never waits.
    private func canAllow(_ review: ToolSummary.Review) -> Bool {
        review.allowsApproval(of: request.id, reviewedRequestID: reviewedRequestID)
    }

    private static func hasNotes(_ review: ToolSummary.Review) -> Bool {
        review.isMultiLine || review.isTruncated || review.hasEscapedCharacters
            || review.hasNonASCII || !review.extraKeys.isEmpty
    }

    private func actions(summary: ToolSummary) -> some View {
        let review = summary.review
        let mustReview = review.requiresExpanding && reviewedRequestID != request.id
        let noun = review.extraKeys.isEmpty ? Self.noun(for: request.toolName) : "input"
        let allowHelp = !review.canApproveHere
            ? "Too long to show here in full. Answer in \(context.hostAppName)."
            : mustReview ? "Open the full \(noun) first" : nil
        return HStack(spacing: 6) {
            if summary.detail != nil {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        isShowingDetail.toggle()
                        if isShowingDetail { reviewedRequestID = request.id }
                    }
                } label: {
                    Label(
                        isShowingDetail ? "Less" : mustReview ? "Show full \(noun)" : "Details",
                        systemImage: isShowingDetail ? "chevron.up" : "chevron.down"
                    )
                    .imageScale(.small)
                }
                .buttonStyle(.pill(mustReview ? .secondary : .quiet))
            }

            Spacer(minLength: 0)

            Button(request.isPlanApproval ? "Keep Planning" : "Deny") { onDecide(.deny) }
                .buttonStyle(.pill(.destructive))
                .help(request.isPlanApproval ? "Reject the plan and keep planning" : "Refuse this tool call")

            if !request.suggestions.isEmpty {
                Button("Always") { onDecide(.allowAlways) }
                    .buttonStyle(.pill(.secondary))
                    .disabled(!canAllow(review))
                    .help(allowHelp ?? "Allow and don't ask again for this kind of call")
            }

            Button(request.isPlanApproval ? "Approve" : "Allow") { onDecide(.allow) }
                .buttonStyle(.pill(.primary))
                .disabled(!canAllow(review))
                .help(allowHelp ?? (request.isPlanApproval ? "Approve the plan and start working" : "Run this tool call once"))
        }
    }

    /// What "Show full …" reveals.
    static func noun(for toolName: String) -> String {
        switch toolName {
        case "Bash": "command"
        case "Edit", "MultiEdit": "change"
        case "Write", "NotebookEdit": "content"
        case "ExitPlanMode": "plan"
        default: "input"
        }
    }
}

// MARK: - Review notes

/// Says why Allow waits: how much there is and whether anything is hidden.
private struct ReviewNotes: View {
    let review: ToolSummary.Review

    var body: some View {
        // One row when it fits, otherwise one chip per line: never clipped.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) { chips }
            VStack(alignment: .leading, spacing: 4) { chips }
        }
    }

    @ViewBuilder
    private var chips: some View {
        ForEach(review.flaggedKeys, id: \.self) { key in
            Chip(text: key, symbol: "exclamationmark.shield", color: .orange)
                .help("This request sets \(key)")
        }
        if review.extraKeys.count > review.flaggedKeys.count {
            let others = review.extraKeys.count - review.flaggedKeys.count
            Chip(text: "\(others) more field\(others == 1 ? "" : "s")", symbol: "curlybraces")
                .help(review.extraKeys.joined(separator: ", "))
        }
        if review.isMultiLine {
            Chip(text: "\(review.lineCount) lines", symbol: "text.alignleft")
        }
        if review.isTruncated {
            Chip(text: "\(review.hiddenCharacters) more characters", symbol: "scissors")
        }
        if review.hasNonASCII {
            Chip(text: "non-ASCII characters", symbol: "character", color: .orange)
                .help("The command contains characters outside ASCII, which can look like others")
        }
        if review.hasEscapedCharacters {
            Chip(text: "hidden characters shown escaped", symbol: "exclamationmark.triangle", color: .orange)
                .help("Control, bidi or invisible characters appear as \\r, \\u{…}")
        }
    }
}

/// The detail was cut for display, so only the terminal can show all of it.
private struct TooLongNote: View {
    let hostAppName: String
    let onSendToTerminal: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("Too long to show here in full.")
                .foregroundStyle(.white.opacity(0.7))
            Spacer(minLength: 0)
            Button("Answer in \(hostAppName)", action: onSendToTerminal)
                .buttonStyle(.pill(.quiet))
        }
        .font(.system(size: 11))
    }
}

// MARK: - Detail

private struct DetailView: View {
    let detail: ToolSummary.Detail

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            content
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 180)
        .fixedSize(horizontal: false, vertical: true)
        .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private var content: some View {
        switch detail {
        case .code(let text), .text(let text):
            Text(text)
                .foregroundStyle(.white.opacity(0.85))
        case .diff(let removed, let added):
            VStack(alignment: .leading, spacing: 0) {
                DiffLines(text: removed, sign: "−", color: .red)
                DiffLines(text: added, sign: "+", color: .green)
            }
        }
    }
}

private struct DiffLines: View {
    let text: String
    let sign: String
    let color: Color

    var body: some View {
        if !text.isEmpty {
            Text(
                text.split(separator: "\n", omittingEmptySubsequences: false)
                    .map { "\(sign) \($0)" }
                    .joined(separator: "\n")
            )
            .foregroundStyle(color.opacity(0.9))
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.12))
        }
    }
}
