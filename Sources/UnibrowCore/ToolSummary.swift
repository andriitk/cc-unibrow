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
    /// One line that identifies the action: a command, a file, a URL.
    public let headline: String
    /// Optional second line, e.g. Claude's own description of a command.
    public let caption: String?
    /// The full content, shown when the card is expanded.
    public let detail: Detail?
    /// SF Symbol name for the tool.
    public let symbol: String

    public init(title: String, headline: String, caption: String? = nil, detail: Detail? = nil, symbol: String) {
        self.title = title
        self.headline = String(headline.prefix(Self.maxHeadlineLength))
        self.caption = caption
        self.detail = detail.map(Self.capped)
        self.symbol = symbol
    }

    /// Display limits. A `Write` of a multi-megabyte file must not turn into a
    /// multi-megabyte `Text` view; the full input still goes to Claude Code.
    static let maxHeadlineLength = 500
    static let maxDetailLength = 20_000

    static func capped(_ detail: Detail) -> Detail {
        func cap(_ text: String) -> String {
            guard text.count > maxDetailLength else { return text }
            return text.prefix(maxDetailLength) + "\n… \(text.count - maxDetailLength) more characters"
        }
        switch detail {
        case .code(let text): return .code(cap(text))
        case .text(let text): return .text(cap(text))
        case .diff(let removed, let added): return .diff(removed: cap(removed), added: cap(added))
        }
    }

    /// - Parameter home: abbreviated to `~` in headlines. Details always keep
    ///   the exact text, so what you approve is what runs.
    public init(toolName: String, input: JSONValue, cwd: String = "", home: String = NSHomeDirectory()) {
        let string = { (key: String) in input[key]?.stringValue }
        let path = { (key: String) in
            string(key).map { Self.abbreviatingHome(Self.relativePath($0, to: cwd), home: home) }
        }

        switch toolName {
        case "Bash":
            let command = string("command") ?? ""
            self.init(
                title: "Bash",
                headline: Self.abbreviatingHome(Self.firstLine(of: command), home: home),
                caption: string("description"),
                detail: .code(command),
                symbol: "terminal"
            )

        case "Edit":
            self.init(
                title: "Edit",
                headline: path("file_path") ?? "file",
                caption: input["replace_all"]?.boolValue == true ? "Replace all occurrences" : nil,
                detail: .diff(removed: string("old_string") ?? "", added: string("new_string") ?? ""),
                symbol: "pencil"
            )

        case "MultiEdit":
            let edits = input["edits"]?.arrayValue ?? []
            self.init(
                title: "Edit",
                headline: path("file_path") ?? "file",
                caption: "\(edits.count) edits",
                detail: .diff(
                    removed: edits.compactMap { $0["old_string"]?.stringValue }.joined(separator: "\n⋯\n"),
                    added: edits.compactMap { $0["new_string"]?.stringValue }.joined(separator: "\n⋯\n")
                ),
                symbol: "pencil"
            )

        case "Write":
            self.init(
                title: "Write",
                headline: path("file_path") ?? "file",
                detail: string("content").map(Detail.code),
                symbol: "doc.badge.plus"
            )

        case "NotebookEdit":
            self.init(
                title: "Notebook",
                headline: path("notebook_path") ?? "notebook",
                detail: string("new_source").map(Detail.code),
                symbol: "book"
            )

        case "Read":
            self.init(title: "Read", headline: path("file_path") ?? "file", symbol: "doc.text")

        case "Glob", "Grep":
            self.init(
                title: toolName,
                headline: string("pattern") ?? "",
                caption: path("path"),
                symbol: "magnifyingglass"
            )

        case "WebFetch":
            self.init(
                title: "Fetch",
                headline: string("url") ?? "",
                caption: string("prompt"),
                symbol: "globe"
            )

        case "WebSearch":
            self.init(title: "Search", headline: string("query") ?? "", symbol: "magnifyingglass.circle")

        case UserQuestion.toolName:
            let questions = UserQuestion.parse(input) ?? []
            self.init(
                title: "Question",
                headline: questions.first?.question ?? "Claude has a question",
                caption: questions.count > 1 ? "\(questions.count) questions" : nil,
                symbol: "questionmark.bubble"
            )

        case "ExitPlanMode":
            let plan = string("plan") ?? ""
            self.init(
                title: "Plan",
                headline: Self.firstLine(of: plan.replacingOccurrences(of: "#", with: "")),
                caption: "Approve the plan and start coding",
                detail: plan.isEmpty ? nil : .text(plan),
                symbol: "list.bullet.clipboard"
            )

        default:
            if let mcp = Self.parseMCP(toolName) {
                self.init(
                    title: "\(mcp.server) · \(mcp.tool)",
                    headline: Self.firstLine(of: Self.inlineArguments(input)),
                    detail: Self.jsonDetail(input),
                    symbol: "puzzlepiece.extension"
                )
            } else {
                self.init(
                    title: toolName,
                    headline: Self.firstLine(of: Self.inlineArguments(input)),
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
        guard let newline = trimmed.firstIndex(of: "\n") else { return trimmed }
        return String(trimmed[..<newline]) + " …"
    }

    /// `{"repo": "x", "title": "y"}` → `repo: x, title: y`.
    static func inlineArguments(_ input: JSONValue) -> String {
        guard let object = input.objectValue, !object.isEmpty else { return "" }
        return object.keys.sorted().map { key in
            let value = object[key].map { value -> String in
                if let string = value.stringValue { return string }
                guard let data = try? value.encoded() else { return "…" }
                return String(decoding: data, as: UTF8.self)
            } ?? ""
            return "\(key): \(value)"
        }.joined(separator: ", ")
    }

    private static func jsonDetail(_ input: JSONValue) -> Detail? {
        guard let object = input.objectValue, !object.isEmpty else { return nil }
        return .code(input.prettyString)
    }
}
