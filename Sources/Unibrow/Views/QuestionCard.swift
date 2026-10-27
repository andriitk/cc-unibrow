import SwiftUI
import UnibrowCore

/// A question Claude asks with `AskUserQuestion`: pick options or type your
/// own answer right in the notch, or hand the whole form to the terminal.
struct QuestionCard: View {
    let context: RequestContext
    let questions: [UserQuestion]
    let onSubmit: ([String: [String]]) -> Void
    let onSendToTerminal: () -> Void

    /// Chosen option labels per question text.
    @State private var selections: [String: [String]] = [:]
    /// Free-text answers per question text; present only while "Other" is on.
    @State private var customAnswers: [String: String] = [:]

    private var answers: [String: [String]] {
        Dictionary(uniqueKeysWithValues: questions.map { question in
            var chosen = selections[question.question] ?? []
            if let text = customAnswers[question.question]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                chosen.append(text)
            }
            return (question.question, chosen)
        })
    }

    private var isComplete: Bool {
        answers.values.allSatisfy { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardHeader(context: context, symbol: "questionmark.bubble", title: "Claude asks")

            ForEach(questions) { question in
                QuestionBlock(
                    question: question,
                    selection: Binding(
                        get: { selections[question.question] ?? [] },
                        set: { selections[question.question] = $0 }
                    ),
                    customAnswer: Binding(
                        get: { customAnswers[question.question] },
                        set: { customAnswers[question.question] = $0 }
                    ),
                    onSubmit: submitIfComplete
                )
            }

            // The actions belong to the whole form, not to the last question.
            Divider()
                .overlay(.white.opacity(0.08))

            HStack(spacing: 6) {
                Button(action: onSendToTerminal) {
                    Label("Answer in \(context.hostAppName)", systemImage: "arrow.up.forward.app")
                        .imageScale(.small)
                }
                .buttonStyle(.pill(.quiet))
                .help("Remove this card and answer in \(context.hostAppName) instead")

                Spacer(minLength: 0)

                Button("Submit", action: submitIfComplete)
                    .buttonStyle(.pill(.primary))
                    .disabled(!isComplete)
                    .opacity(isComplete ? 1 : 0.4)
            }
        }
        .cardBackground()
    }

    private func submitIfComplete() {
        guard isComplete else { return }
        let typedSomething = customAnswers.values.contains { !$0.isEmpty }
        onSubmit(answers)
        // The panel held the keyboard while typing; hand focus back to the terminal.
        if typedSomething { context.bringToFront() }
    }
}

private struct QuestionBlock: View {
    let question: UserQuestion
    @Binding var selection: [String]
    /// `nil` while "Other" is off; a string (possibly empty) while it is on.
    @Binding var customAnswer: String?
    let onSubmit: () -> Void

    @Environment(\.beginTyping) private var beginTyping
    @FocusState private var isTyping: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let header = question.header, !header.isEmpty {
                    Chip(text: header, symbol: nil)
                }
                if question.allowsMultipleAnswers {
                    Text("choose any")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            Text(question.question)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(question.options, id: \.label) { option in
                    OptionRow(
                        label: option.label,
                        description: option.description,
                        isSelected: selection.contains(option.label),
                        action: { toggle(option.label) }
                    )
                }
                otherRow
            }
        }
    }

    @ViewBuilder
    private var otherRow: some View {
        if customAnswer == nil {
            OptionRow(label: "Other…", description: "Type your own answer", isSelected: false) {
                if !question.allowsMultipleAnswers { selection = [] }
                customAnswer = ""
                startTyping()
            }
        } else {
            HStack(spacing: 8) {
                Image(systemName: "largecircle.fill.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.orange)
                TextField("Your answer", text: Binding(
                    get: { customAnswer ?? "" },
                    set: { customAnswer = $0 }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .focused($isTyping)
                .onSubmit(onSubmit)
                Button {
                    customAnswer = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
                .help("Cancel your own answer")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.white.opacity(0.12))
            )
            .onTapGesture(perform: startTyping)
        }
    }

    private func startTyping() {
        beginTyping()
        // Focus on the next run-loop turn, once the panel has become key.
        Task { @MainActor in isTyping = true }
    }

    private func toggle(_ label: String) {
        if question.allowsMultipleAnswers {
            if let index = selection.firstIndex(of: label) {
                selection.remove(at: index)
            } else {
                selection.append(label)
            }
        } else {
            selection = [label]
            customAnswer = nil
        }
    }
}

/// One selectable option; also used by `ElicitationCard`.
struct OptionRow: View {
    let label: String
    let description: String?
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? Color.orange : .white.opacity(0.4))
                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                    if let description, !description.isEmpty {
                        Text(description)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.white.opacity(isSelected ? 0.12 : (isHovered ? 0.07 : 0.03)))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
