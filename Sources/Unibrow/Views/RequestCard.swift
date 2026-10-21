import AppKit
import SwiftUI
import UnibrowCore

/// One pending permission request: what Claude wants to do, and the answers.
struct RequestCard: View {
    let context: RequestContext
    let onDecide: (AppModel.Choice) -> Void
    let onSendToTerminal: () -> Void

    @State private var isShowingDetail = false

    private var request: PendingRequest { context.request }

    var body: some View {
        let summary = ToolSummary(toolName: request.toolName, input: request.toolInput, cwd: request.cwd)
        VStack(alignment: .leading, spacing: 8) {
            CardHeader(context: context, symbol: summary.symbol, title: summary.title)

            Text(summary.headline.isEmpty ? "—" : summary.headline)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.white)
                .lineLimit(isShowingDetail ? nil : 2)
                .truncationMode(.middle)
                .textSelection(.enabled)

            if let caption = summary.caption, !caption.isEmpty {
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(2)
            }

            if isShowingDetail, let detail = summary.detail {
                DetailView(detail: detail)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            actions(hasDetail: summary.detail != nil)
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

    private func actions(hasDetail: Bool) -> some View {
        HStack(spacing: 6) {
            if hasDetail {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { isShowingDetail.toggle() }
                } label: {
                    Label(isShowingDetail ? "Less" : "Details", systemImage: isShowingDetail ? "chevron.up" : "chevron.down")
                        .imageScale(.small)
                }
                .buttonStyle(.pill(.quiet))
            }

            Spacer(minLength: 0)

            Button(request.isPlanApproval ? "Keep Planning" : "Deny") { onDecide(.deny) }
                .buttonStyle(.pill(.destructive))
                .help(request.isPlanApproval ? "Reject the plan and keep planning" : "Refuse this tool call")

            if !request.suggestions.isEmpty {
                Button("Always") { onDecide(.allowAlways) }
                    .buttonStyle(.pill(.secondary))
                    .help("Allow and don't ask again for this kind of call")
            }

            Button(request.isPlanApproval ? "Approve" : "Allow") { onDecide(.allow) }
                .buttonStyle(.pill(.primary))
                .help(request.isPlanApproval ? "Approve the plan and start working" : "Run this tool call once")
        }
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
