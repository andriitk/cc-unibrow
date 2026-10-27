public import Foundation

/// A compact, human-readable description of what a tool wants to do.
///
/// Kept in the core module (not in the views) so every tool mapping is tested.
public struct ToolSummary: Sendable, Equatable {
    public enum Detail: Sendable, Equatable {
        /// A shell command or other code-like text.
        case code(String)
        /// An edit: text that goes away and text that replaces it.
        case diff(removed: String, added: String)
        /// Free-form text, e.g. a URL, a query or pretty-printed JSON.
        case text(String)
    }

    /// Tool name as shown to the user, e.g. "Bash" or "github · create_issue".
    public let title: String
    /// One line that identifies the action: a command, a file, a URL. Cut for
    /// display, with invisible characters escaped: a label, not the input.
    public let headline: String
    /// Optional second line, e.g. Claude's own description of a command.
    public let caption: String?
    /// The full content, shown when the card is expanded. Capped for display
    /// and escaped; `review` says whether anything was left out.
    public let detail: Detail?
    /// SF Symbol name for the tool.
    public let symbol: String
    /// What the card must show before it may offer Allow.
    public let review: Review

    /// How much of the input the collapsed card shows, so the app never lets
    /// someone approve text they could not see (a long command whose dangerous
    /// part is past the cut, a second line, a `\r` that overwrites the first).
    public struct Review: Sendable, Equatable {
        /// The headline alone shows the whole input: one short line with
        /// nothing escaped. Otherwise the detail has to be opened first.
        public let fitsInHeadline: Bool
        /// Lines in the detail (both sides of a diff together).
        public let lineCount: Int
        /// Characters cut from the detail; Claude Code still gets all of them.
        public let hiddenCharacters: Int
        /// The input contains control, bidi or invisible characters, shown escaped.
        public let hasEscapedCharacters: Bool
        /// A command contains non-ASCII characters, which can look like ASCII
        /// (homoglyphs) or hide; the detail has to be opened.
        public let hasNonASCII: Bool
        /// Input fields the card has no place for, e.g. `timeout` or a field a
        /// future Claude Code adds. With any of them the detail is the full input.
        public let extraKeys: [String]
        /// Extra fields that change how safely the tool runs, such as
        /// `dangerouslyDisableSandbox`. The card calls them out.
        public let flaggedKeys: [String]

        init(
            fitsInHeadline: Bool,
            lineCount: Int,
            hiddenCharacters: Int,
            hasEscapedCharacters: Bool,
            hasNonASCII: Bool = false,
            extraKeys: [String] = []
        ) {
            self.fitsInHeadline = fitsInHeadline && !hasNonASCII && extraKeys.isEmpty
            self.lineCount = lineCount
            self.hiddenCharacters = hiddenCharacters
            self.hasEscapedCharacters = hasEscapedCharacters
            self.hasNonASCII = hasNonASCII
            self.extraKeys = extraKeys
            self.flaggedKeys = extraKeys.filter(ToolSummary.isSecuritySensitive)
        }

        public var isTruncated: Bool { hiddenCharacters > 0 }
        public var isMultiLine: Bool { lineCount > 1 }
        /// Allow waits until the user opened the detail.
        public var requiresExpanding: Bool { !fitsInHeadline }
        /// Only a complete detail can be approved here; a truncated one goes
        /// to the terminal, which shows everything.
        public var canApproveHere: Bool { !isTruncated }

        /// Whether the card may enable Allow for `requestID`. `reviewedRequestID`
        /// is the request whose detail the user opened; comparing IDs keeps a
        /// review from carrying over to another request that reuses the view.
        public func allowsApproval<ID: Equatable>(of requestID: ID, reviewedRequestID: ID?) -> Bool {
            canApproveHere && (fitsInHeadline || reviewedRequestID == requestID)
        }
    }

    /// - Parameter headlineIsComplete: the headline is derived from the whole
    ///   input (a command, the inline arguments), so when it is one short line
    ///   it shows everything there is. False when the detail holds other
    ///   content (a diff, file contents, a plan).
    public init(
        title: String,
        headline: String,
        caption: String? = nil,
        detail: Detail? = nil,
        symbol: String,
        headlineIsComplete: Bool = true,
        flagsNonASCII: Bool = false
    ) {
        let headlineFits = Self.fitsOnOneLine(headline)
        // A long or multi-line headline with nothing behind it gets a detail,
        // so the whole value can still be read before approving.
        let detail = detail ?? (headlineFits ? nil : .text(headline))
        let display = detail.map(Self.displayed)

        self.title = title
        self.headline = String(Self.escaped(Self.firstLine(of: headline)).text.prefix(Self.maxHeadlineLength))
        self.caption = caption
        self.detail = display?.detail
        self.symbol = symbol
        self.review = Review(
            fitsInHeadline: detail == nil || (headlineIsComplete && headlineFits),
            lineCount: display?.lineCount ?? (headline.isEmpty ? 0 : 1),
            hiddenCharacters: display?.hiddenCharacters ?? 0,
            hasEscapedCharacters: (display?.hasEscapedCharacters ?? false) || Self.escaped(headline).changed,
            hasNonASCII: flagsNonASCII && !headline.unicodeScalars.allSatisfy(\.isASCII)
        )
    }

    private init(title: String, headline: String, caption: String?, detail: Detail?, symbol: String, review: Review) {
        self.title = title
        self.headline = headline
        self.caption = caption
        self.detail = detail
        self.symbol = symbol
        self.review = review
    }

    /// The same card, but its detail becomes the whole input as JSON, because
    /// the input has fields the card would not show otherwise.
    private func showingFullInput(_ input: JSONValue, extraKeys: [String]) -> ToolSummary {
        let full = ToolSummary(title: title, headline: "", detail: .code(input.prettyString), symbol: symbol)
        return ToolSummary(
            title: title,
            headline: headline,
            caption: caption,
            detail: full.detail,
            symbol: symbol,
            review: Review(
                fitsInHeadline: false,
                lineCount: full.review.lineCount,
                hiddenCharacters: full.review.hiddenCharacters,
                hasEscapedCharacters: review.hasEscapedCharacters || full.review.hasEscapedCharacters,
                hasNonASCII: review.hasNonASCII,
                extraKeys: extraKeys
            )
        )
    }

    /// Input fields each tool's card shows, or that cannot change what the
    /// tool does beyond that (`Read`'s range, `Grep`'s filters). `nil` means
    /// the headline lists every field (MCP and unknown tools).
    static func representedKeys(for toolName: String) -> Set<String>? {
        switch toolName {
        case "Bash": ["command", "description"]
        case "Edit": ["file_path", "old_string", "new_string", "replace_all"]
        case "MultiEdit": ["file_path", "edits"]
        case "Write": ["file_path", "content"]
        case "NotebookEdit": ["notebook_path", "new_source"]
        case "Read": ["file_path", "offset", "limit", "pages"]
        case "Glob": ["pattern", "path"]
        case "Grep":
            ["pattern", "path", "glob", "type", "output_mode", "-i", "-n", "-A", "-B", "-C",
             "context", "multiline", "head_limit", "offset"]
        case "WebFetch": ["url", "prompt"]
        case "WebSearch": ["query"]
        case "ExitPlanMode": ["plan"]
        default: nil
        }
    }

    /// Sorted input fields the card for `toolName` would not show.
    static func extraKeys(toolName: String, input: JSONValue) -> [String] {
        guard let known = representedKeys(for: toolName), let object = input.objectValue else { return [] }
        var extra = object.keys.filter { !known.contains($0) }
        if toolName == "MultiEdit" {
            let editKeys: Set<String> = ["old_string", "new_string", "replace_all"]
            for edit in object["edits"]?.arrayValue ?? [] {
                guard let fields = edit.objectValue else {
                    extra.append("edits[]")
                    continue
                }
                extra += fields.keys.filter { !editKeys.contains($0) }.map { "edits[].\($0)" }
            }
        }
        return Array(Set(extra)).sorted()
    }

    /// Fields that weaken a safety check, whatever the tool.
    static func isSecuritySensitive(_ key: String) -> Bool {
        let lowered = key.lowercased()
        return lowered.contains("dangerous") || lowered.contains("sandbox") || lowered.contains("bypass")
            || lowered.contains("skip") && lowered.contains("permission")
    }

    /// Display limits. A `Write` of a multi-megabyte file must not turn into a
    /// multi-megabyte `Text` view; the full input still goes to Claude Code.
    static let maxHeadlineLength = 500
    static let maxDetailLength = 20_000
    /// Longest input the collapsed card shows in full without a review. The
    /// headline wraps rather than truncates up to this length.
    static let maxInlineLength = 120

    /// One short line with nothing that needs escaping.
    static func fitsOnOneLine(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count <= maxInlineLength
            && !trimmed.contains(where: \.isNewline)
            && !escaped(trimmed).changed
    }

    private static func displayed(_ detail: Detail) -> (detail: Detail, lineCount: Int, hiddenCharacters: Int, hasEscapedCharacters: Bool) {
        var lines = 0, hidden = 0, escapedAny = false
        func show(_ text: String) -> String {
            lines += lineCount(of: text)
            let shown: String
            if text.count > maxDetailLength {
                hidden += text.count - maxDetailLength
                shown = String(text.prefix(maxDetailLength))
            } else {
                shown = text
            }
            let result = escaped(shown)
            escapedAny = escapedAny || result.changed
            return result.text
        }
        let capped: Detail
        switch detail {
        case .code(let text): capped = .code(withNote(show(text), text))
        case .text(let text): capped = .text(withNote(show(text), text))
        case .diff(let removed, let added):
            capped = .diff(removed: withNote(show(removed), removed), added: withNote(show(added), added))
        }
        return (capped, lines, hidden, escapedAny)
    }

    private static func withNote(_ shown: String, _ original: String) -> String {
        guard original.count > maxDetailLength else { return shown }
        return shown + "\n… \(original.count - maxDetailLength) more characters"
    }

    static func lineCount(of text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        let trimmed = text.trimmingCharacters(in: .newlines)
        return trimmed.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count
    }

    /// Makes characters that could hide or rearrange text visible: control
    /// characters (`\r`, ANSI `ESC`, backspace…), bidi overrides and isolates,
    /// zero-width and other invisible format characters, Unicode line breaks.
    /// Newlines and tabs stay, so code still reads as code. ZWJ stays too:
    /// it only joins emoji.
    static func escaped(_ text: String) -> (text: String, changed: Bool) {
        var previous: Unicode.Scalar?
        guard text.unicodeScalars.contains(where: { defer { previous = $0 }; return needsEscape($0, after: previous) })
        else { return (text, false) }
        previous = nil
        var result = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            defer { previous = scalar }
            guard needsEscape(scalar, after: previous) else {
                result.append(scalar)
                continue
            }
            let escape: String
            switch scalar {
            case "\r": escape = "\\r"
            case "\0": escape = "\\0"
            default: escape = "\\u{" + String(scalar.value, radix: 16, uppercase: true) + "}"
            }
            result.append(contentsOf: escape.unicodeScalars)
        }
        return (String(result), true)
    }

    private static func needsEscape(_ scalar: Unicode.Scalar, after previous: Unicode.Scalar?) -> Bool {
        if scalar.isASCII {
            return scalar != "\n" && scalar != "\t" && scalar.properties.generalCategory == .control
        }
        let properties = scalar.properties
        // ZWJ and emoji variation selectors are invisible on their own but
        // only join or style the emoji right before them: 👨‍👩‍👧, ❤️.
        if scalar == "\u{200D}" || scalar == "\u{FE0E}" || scalar == "\u{FE0F}" {
            guard let previous else { return true }
            let joinsEmoji = (previous.properties.isEmoji && !previous.isASCII)
                || (scalar == "\u{200D}" && previous == "\u{FE0F}")
            return !joinsEmoji
        }
        switch properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator, .spaceSeparator: return true
        default: break
        }
        // Default-ignorable code points render as nothing: zero-width
        // characters, variation selectors, Hangul fillers, tag characters.
        return properties.isDefaultIgnorableCodePoint
            || properties.isWhitespace
            || scalar == "\u{2800}" // braille blank looks like a space
            || scalar == "\u{115F}" || scalar == "\u{1160}" || scalar == "\u{3164}" || scalar == "\u{FFA0}"
            || (0xE0000...0xE007F).contains(scalar.value)
    }

    /// - Parameter home: abbreviated to `~` in headlines. Details always keep
    ///   the exact text, so what you approve is what runs.
    public init(toolName: String, input: JSONValue, cwd: String = "", home: String = NSHomeDirectory()) {
        let summary = Self.mapped(toolName: toolName, input: input, cwd: cwd, home: home)
        let extra = Self.extraKeys(toolName: toolName, input: input)
        self = extra.isEmpty ? summary : summary.showingFullInput(input, extraKeys: extra)
    }

    private static func mapped(toolName: String, input: JSONValue, cwd: String, home: String) -> ToolSummary {
        let string = { (key: String) in input[key]?.stringValue }
        let path = { (key: String) in
            string(key).map { Self.abbreviatingHome(Self.relativePath($0, to: cwd), home: home) }
        }

        switch toolName {
        case "Bash":
            let command = string("command") ?? ""
            return ToolSummary(
                title: "Bash",
                headline: Self.abbreviatingHome(command, home: home),
                caption: string("description"),
                detail: .code(command),
                symbol: "terminal",
                flagsNonASCII: true
            )

        case "Edit":
            return ToolSummary(
                title: "Edit",
                headline: path("file_path") ?? "file",
                caption: input["replace_all"]?.boolValue == true ? "Replace all occurrences" : nil,
                detail: .diff(removed: string("old_string") ?? "", added: string("new_string") ?? ""),
                symbol: "pencil",
                headlineIsComplete: false
            )

        case "MultiEdit":
            let edits = input["edits"]?.arrayValue ?? []
            return ToolSummary(
                title: "Edit",
                headline: path("file_path") ?? "file",
                caption: edits.contains { $0["replace_all"]?.boolValue == true }
                    ? "\(edits.count) edits, some replace all occurrences"
                    : "\(edits.count) edits",
                detail: .diff(
                    removed: edits.compactMap { $0["old_string"]?.stringValue }.joined(separator: "\n⋯\n"),
                    added: edits.compactMap { $0["new_string"]?.stringValue }.joined(separator: "\n⋯\n")
                ),
                symbol: "pencil",
                headlineIsComplete: false
            )

        case "Write":
            return ToolSummary(
                title: "Write",
                headline: path("file_path") ?? "file",
                detail: string("content").map(Detail.code),
                symbol: "doc.badge.plus",
                headlineIsComplete: false
            )

        case "NotebookEdit":
            return ToolSummary(
                title: "Notebook",
                headline: path("notebook_path") ?? "notebook",
                detail: string("new_source").map(Detail.code),
                symbol: "book",
                headlineIsComplete: false
            )

        case "Read":
            return ToolSummary(title: "Read", headline: path("file_path") ?? "file", symbol: "doc.text")

        case "Glob", "Grep":
            return ToolSummary(
                title: toolName,
                headline: string("pattern") ?? "",
                caption: path("path"),
                symbol: "magnifyingglass"
            )

        case "WebFetch":
            return ToolSummary(
                title: "Fetch",
                headline: string("url") ?? "",
                caption: string("prompt"),
                symbol: "globe"
            )

        case "WebSearch":
            return ToolSummary(title: "Search", headline: string("query") ?? "", symbol: "magnifyingglass.circle")

        case UserQuestion.toolName:
            let questions = UserQuestion.parse(input) ?? []
            return ToolSummary(
                title: "Question",
                headline: questions.first?.question ?? "Claude has a question",
                caption: questions.count > 1 ? "\(questions.count) questions" : nil,
                symbol: "questionmark.bubble"
            )

        case "ExitPlanMode":
            let plan = string("plan") ?? ""
            return ToolSummary(
                title: "Plan",
                headline: plan.replacingOccurrences(of: "#", with: ""),
                caption: "Approve the plan and start coding",
                detail: plan.isEmpty ? nil : .text(plan),
                symbol: "list.bullet.clipboard",
                headlineIsComplete: false
            )

        default:
            if let mcp = Self.parseMCP(toolName) {
                return ToolSummary(
                    title: "\(mcp.server) · \(mcp.tool)",
                    headline: Self.inlineArguments(input),
                    detail: Self.jsonDetail(input),
                    symbol: "puzzlepiece.extension"
                )
            } else {
                return ToolSummary(
                    title: toolName,
                    headline: Self.inlineArguments(input),
                    detail: Self.jsonDetail(input),
                    symbol: "wrench.and.screwdriver"
                )
            }
        }
    }

    // MARK: - Helpers

    /// `mcp__github__create_issue` → (github, create_issue).
    static func parseMCP(_ toolName: String) -> (server: String, tool: String)? {
        let parts = toolName.components(separatedBy: "__")
        guard parts.count >= 3, parts[0] == "mcp" else { return nil }
        return (parts[1], parts[2...].joined(separator: "__"))
    }

    /// Shows paths inside the project relative to it; others stay absolute.
    static func relativePath(_ path: String, to cwd: String) -> String {
        guard !cwd.isEmpty else { return path }
        let prefix = cwd.hasSuffix("/") ? cwd : cwd + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    /// `/Users/me/x` → `~/x`. Only whole path prefixes are replaced, so
    /// `/Users/meg` is left alone when home is `/Users/me`.
    static func abbreviatingHome(_ text: String, home: String) -> String {
        guard !home.isEmpty, home != "/" else { return text }
        let homeSlash = home.hasSuffix("/") ? home : home + "/"
        let bare = String(homeSlash.dropLast())
        var result = text.replacingOccurrences(of: homeSlash, with: "~/")
        // A bare home at the end of the text or before a quote/space.
        for terminator in ["\"", "'", " "] {
            result = result.replacingOccurrences(of: bare + terminator, with: "~" + terminator)
        }
        if result.hasSuffix(bare) { result = String(result.dropLast(bare.count)) + "~" }
        return result
    }

    static func firstLine(of text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Any line break, not just "\n": "\r\n", a lone "\r" and U+2028 too.
        guard let newline = trimmed.firstIndex(where: \.isNewline) else { return trimmed }
        return String(trimmed[..<newline]) + " …"
    }

    /// `{"repo": "x", "n": 3}` → `n: 3, repo: "x"`. Values are JSON, so a
    /// value such as `x", force: "true` cannot pose as another field, and a
    /// newline shows as `\n`. Keys other than plain identifiers are quoted too.
    static func inlineArguments(_ input: JSONValue) -> String {
        guard let object = input.objectValue, !object.isEmpty else { return "" }
        func json(_ value: JSONValue) -> String {
            guard let data = try? value.encoded() else { return "…" }
            return String(decoding: data, as: UTF8.self)
        }
        return object.keys.sorted().map { key in
            let plain = !key.isEmpty && key.unicodeScalars.allSatisfy {
                $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "_-.".unicodeScalars.contains($0))
            }
            return "\(plain ? key : json(.string(key))): \(object[key].map(json) ?? "null")"
        }.joined(separator: ", ")
    }

    private static func jsonDetail(_ input: JSONValue) -> Detail? {
        guard let object = input.objectValue, !object.isEmpty else { return nil }
        return .code(input.prettyString)
    }
}
