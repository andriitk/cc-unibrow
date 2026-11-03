import UnibrowCore

/// Which card a request gets.
enum CardKind: Equatable {
    /// An MCP server asks for input.
    case elicitation(ElicitationRequest)
    /// `AskUserQuestion` with questions the card can show.
    case question([UserQuestion])
    /// Everything else, including a question whose input cannot be read:
    /// Allow, Always, Deny.
    case permission

    init(_ request: PendingRequest) {
        if let elicitation = request.elicitation {
            self = .elicitation(elicitation)
        } else if request.isQuestion, let questions = UserQuestion.parse(request.toolInput) {
            self = .question(questions)
        } else {
            self = .permission
        }
    }
}

/// A card's buttons, bound to one request and the host that answers it.
@MainActor
struct CardActions {
    let decide: (PermissionChoice) -> Void
    let answer: ([String: [String]]) -> Void
    let answerElicitation: (ElicitationAnswer) -> Void
    let openLink: () -> Void
    let sendToTerminal: () -> Void
    let bringToFront: () -> Void

    init(host: any NotchHost, request: PendingRequest) {
        decide = { host.decide(request, $0) }
        answer = { host.answer(request, with: $0) }
        answerElicitation = { host.answerElicitation(request, $0) }
        openLink = { host.openElicitationLink(request) }
        sendToTerminal = { host.sendToTerminal(request) }
        bringToFront = { host.bringToFront(request) }
    }
}
