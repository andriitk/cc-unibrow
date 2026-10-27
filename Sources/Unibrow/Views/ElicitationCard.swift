import SwiftUI
import UnibrowCore

/// An MCP server asks for input: a small form, or a link to open.
///
/// Every string on this card comes from the MCP server and is escaped by
/// `ElicitationRequest`. Values the user types are never logged.
struct ElicitationCard: View {
    let context: RequestContext
    let elicitation: ElicitationRequest
    let onAnswer: (ElicitationAnswer) -> Void
    let onOpenLink: () -> Void
    let onSendToTerminal: () -> Void

    @State private var values: [String: ElicitationValue]
    /// Fields the user edited: their errors show while typing. Every error
    /// shows after a submit attempt.
    @State private var touched: Set<String> = []
    @State private var triedSubmit = false
    @FocusState private var focusedField: String?
    @Environment(\.beginTyping) private var beginTyping

    init(
        context: RequestContext,
        elicitation: ElicitationRequest,
        onAnswer: @escaping (ElicitationAnswer) -> Void,
        onOpenLink: @escaping () -> Void,
        onSendToTerminal: @escaping () -> Void
    ) {
        self.context = context
        self.elicitation = elicitation
        self.onAnswer = onAnswer
        self.onOpenLink = onOpenLink
        self.onSendToTerminal = onSendToTerminal
        if case .form(let form) = elicitation.content {
            _values = State(initialValue: form.initialValues)
        } else {
            _values = State(initialValue: [:])
        }
    }

    static func symbol(for elicitation: ElicitationRequest) -> String {
        switch elicitation.content {
        case .form: "list.bullet.rectangle"
        case .url: "link"
        case .unsupported: "puzzlepiece.extension"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardHeader(context: context, symbol: Self.symbol(for: elicitation), title: elicitation.serverName)

            if !elicitation.message.isEmpty {
                Text(elicitation.message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            if elicitation.hasEscapedCharacters || elicitation.isMessageTruncated {
                NoteChips {
                    if elicitation.hasEscapedCharacters {
                        Chip(text: "hidden characters shown escaped", symbol: "exclamationmark.triangle", color: .orange)
                            .help("Control, bidi or invisible characters appear as \\u{…}")
                    }
                    if elicitation.isMessageTruncated {
                        Chip(text: "message shortened", symbol: "scissors")
                    }
                }
            }

            switch elicitation.content {
            case .form(let form):
                if !form.fields.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(form.fields) { field in
                            fieldView(field, error: shownError(for: field, in: form))
                        }
                    }
                }
            case .url(let link):
                LinkView(link: link)
            case .unsupported(let reason):
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("\(reason) Answer it in \(context.hostAppName).")
                        .foregroundStyle(.white.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 11))
            }

            Divider()
                .overlay(.white.opacity(0.08))

            actions
        }
        .cardBackground()
    }

    // MARK: - Actions

    private var actions: some View {
        HStack(spacing: 6) {
            if case .unsupported = elicitation.content {
                EmptyView()
            } else {
                Button(action: onSendToTerminal) {
                    Label("Answer in \(context.hostAppName)", systemImage: "arrow.up.forward.app")
                        .imageScale(.small)
                }
                .buttonStyle(.pill(.quiet))
                .help("Remove this card and answer in \(context.hostAppName) instead")
            }

            Spacer(minLength: 0)

            Button("Cancel") { onAnswer(.cancel) }
                .buttonStyle(.pill(.quiet))
                .help("Dismiss without answering (the server sees “cancel”)")

            Button("Decline") { onAnswer(.decline) }
                .buttonStyle(.pill(.destructive))
                .help("Refuse to provide this (the server sees “decline”)")

            switch elicitation.content {
            case .form:
                Button("Submit", action: submit)
                    .buttonStyle(.pill(.primary))
            case .url(let link):
                Button("Open", action: onOpenLink)
                    .buttonStyle(.pill(.primary))
                    .disabled(link.openableURL == nil)
                    .opacity(link.openableURL == nil ? 0.4 : 1)
                    .help(link.refusal.map { "\($0.reason) Answer in \(context.hostAppName)." }
                        ?? "Open \(link.host) in your browser")
            case .unsupported:
                Button("Answer in \(context.hostAppName)", action: onSendToTerminal)
                    .buttonStyle(.pill(.secondary))
            }
        }
    }

    private func submit() {
        guard case .form(let form) = elicitation.content else { return }
        guard let content = form.content(for: values) else {
            triedSubmit = true
            return
        }
        let typed = focusedField != nil || !touched.isEmpty
        onAnswer(.accept(content: content))
        // The panel held the keyboard while typing; hand focus back.
        if typed { context.bringToFront() }
    }

    // MARK: - Fields

    private func shownError(for field: ElicitationField, in form: ElicitationForm) -> String? {
        guard triedSubmit || touched.contains(field.name) else { return nil }
        return form.errors(for: values)[field.name]
    }

    private func fieldView(_ field: ElicitationField, error: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(field.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(2)
                if field.isRequired {
                    Text("*")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.orange)
                        .help("Required")
                }
                if field.isSensitive {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.45))
                        .help("Hidden while you type")
                }
            }

            input(for: field)

            if let description = field.description {
                Text(description)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error {
                Text(error)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color(red: 1, green: 0.5, blue: 0.45))
            }
        }
    }

    @ViewBuilder
    private func input(for field: ElicitationField) -> some View {
        switch field.kind {
        case .text, .number:
            textInput(for: field)
        case .boolean:
            Toggle(isOn: Binding(
                get: { if case .flag(let flag)? = values[field.name] { flag ?? false } else { false } },
                set: { values[field.name] = .flag($0); touched.insert(field.name) }
            )) {
                Text("Yes")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
        case .choice(let options, let multiple, _, _):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(options, id: \.value) { option in
                    OptionRow(
                        label: option.title,
                        description: nil,
                        isSelected: chosen(field).contains(option.value),
                        action: { toggle(option.value, in: field, multiple: multiple) }
                    )
                }
            }
        }
    }

    private func textInput(for field: ElicitationField) -> some View {
        let binding = Binding(
            get: { if case .text(let text)? = values[field.name] { text } else { "" } },
            set: { values[field.name] = .text($0); touched.insert(field.name) }
        )
        let placeholder = Self.placeholder(for: field)
        return Group {
            if field.isSensitive {
                SecureField(placeholder, text: binding)
            } else {
                TextField(placeholder, text: binding)
            }
        }
        .textFieldStyle(.plain)
        .font(.system(size: 12))
        .foregroundStyle(.white)
        .focused($focusedField, equals: field.name)
        .onSubmit(submit)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.white.opacity(focusedField == field.name ? 0.14 : 0.08))
        )
        .contentShape(Rectangle())
        .onTapGesture { startTyping(field.name) }
    }

    private func startTyping(_ name: String) {
        beginTyping()
        // Focus on the next run-loop turn, once the panel has become key.
        Task { @MainActor in focusedField = name }
    }

    private func chosen(_ field: ElicitationField) -> [String] {
        if case .choices(let values)? = values[field.name] { values } else { [] }
    }

    private func toggle(_ value: String, in field: ElicitationField, multiple: Bool) {
        var current = chosen(field)
        if multiple {
            if let index = current.firstIndex(of: value) { current.remove(at: index) } else { current.append(value) }
        } else {
            current = current == [value] && !field.isRequired ? [] : [value]
        }
        values[field.name] = .choices(current)
        touched.insert(field.name)
    }

    static func placeholder(for field: ElicitationField) -> String {
        switch field.kind {
        case .text(let format, _, _):
            switch format {
            case .email?: return "name@example.com"
            case .uri?: return "https://…"
            case .date?: return "YYYY-MM-DD"
            case .dateTime?: return "YYYY-MM-DDThh:mm:ssZ"
            case nil: return field.isRequired ? "Required" : "Optional"
            }
        case .number(let integer, let minimum, let maximum):
            let noun = integer ? "Whole number" : "Number"
            switch (minimum, maximum) {
            case (let low?, let high?): return "\(noun), \(Self.format(low))–\(Self.format(high))"
            case (let low?, nil): return "\(noun), at least \(Self.format(low))"
            case (nil, let high?): return "\(noun), at most \(Self.format(high))"
            case (nil, nil): return noun
            }
        default:
            return ""
        }
    }

    private static func format(_ number: Double) -> String {
        number == number.rounded() && abs(number) < 1e15 ? String(Int64(number)) : String(number)
    }
}

// MARK: - URL

/// The URL in full, with the host (where the browser really goes) highlighted,
/// and the things that make a link suspicious called out.
private struct LinkView: View {
    let link: ElicitationLink

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(highlighted)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            NoteChips {
                if !link.host.isEmpty {
                    Chip(text: Chip.shortened(link.host, limit: 40), symbol: "globe", color: .white.opacity(0.8))
                        .help("The browser opens \(link.host)")
                }
                if let refusal = link.refusal {
                    Chip(text: "won't open from here", symbol: "hand.raised", color: .orange)
                        .help(refusal.reason)
                } else if !link.isEncrypted {
                    Chip(text: "not HTTPS", symbol: "lock.open", color: .orange)
                }
                if link.hasUserInfo {
                    Chip(text: "user@ before the host", symbol: "exclamationmark.shield", color: .orange)
                        .help("Everything before @ is a user name, not the site; the site is \(link.host)")
                }
                if link.hasInternationalHost {
                    Chip(text: link.unicodeHost.map { "international host: \(Chip.shortened($0, limit: 30))" } ?? "international host name",
                         symbol: "character", color: .orange)
                        .help("Shown as punycode. Look-alike characters can imitate another site.")
                }
                if link.hasEscapedCharacters {
                    Chip(text: "hidden characters shown escaped", symbol: "exclamationmark.triangle", color: .orange)
                }
                if link.isTruncated {
                    Chip(text: "long URL shortened", symbol: "scissors")
                }
            }
        }
    }

    private var highlighted: AttributedString {
        var prefix = AttributedString(link.prefix)
        prefix.foregroundColor = .white.opacity(0.5)
        var host = AttributedString(link.host)
        host.foregroundColor = .orange
        host.font = .system(size: 11, weight: .bold, design: .monospaced)
        var suffix = AttributedString(link.suffix)
        suffix.foregroundColor = .white.opacity(0.5)
        return prefix + host + suffix
    }
}

/// Note chips on one row when they fit, one per line otherwise.
struct NoteChips<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) { content }
            VStack(alignment: .leading, spacing: 4) { content }
        }
    }
}
