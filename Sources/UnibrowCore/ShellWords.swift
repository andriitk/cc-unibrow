import Foundation

/// A shell command line read into simple commands and words, as far as that
/// is possible without running a shell.
///
/// Used only to recognise risky commands for an impact note, so it is
/// conservative: anything it cannot read exactly (subshells, groups, here
/// documents, control keywords) makes `parse` return `nil`, and a word whose
/// value depends on the shell (a variable other than `HOME`, a command
/// substitution, a glob) is marked as not literal. The caller then shows
/// nothing rather than something wrong.
public enum ShellWords {
    public struct Word: Sendable, Equatable {
        /// The value after quote removal (and `~`, `$HOME` expansion).
        public var text: String
        /// The word as typed, quotes included.
        public var raw: String
        /// The shell would not change `text`: no other variable, command
        /// substitution or glob in it.
        public var isLiteral: Bool

        public init(text: String, raw: String, isLiteral: Bool = true) {
            self.text = text
            self.raw = raw
            self.isLiteral = isLiteral
        }
    }

    /// Simple commands in order, redirections removed. `nil` when the line
    /// has a construct this reader does not follow.
    public static func parse(_ line: String, home: String) -> [[Word]]? {
        var reader = Reader(scalars: Array(line.unicodeScalars), home: home)
        guard let commands = reader.read() else { return nil }
        // Control structures and groups change what runs and where; skip them.
        let keywords: Set<String> = [
            "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done",
            "case", "esac", "select", "function", "{", "}", "[[", "]]", "!", "coproc",
        ]
        for command in commands where command.first.map({ keywords.contains($0.raw) }) == true {
            return nil
        }
        return commands.filter { !$0.isEmpty }
    }

    /// Longest command line read; anything longer is not analysed.
    static let maxLength = 20_000

    private struct Reader {
        let scalars: [Unicode.Scalar]
        let home: String
        var index = 0

        var commands: [[Word]] = []
        var words: [Word] = []
        var text = String.UnicodeScalarView()
        var raw = String.UnicodeScalarView()
        var literal = true
        var inWord = false
        /// The next word is a redirection target, not an argument.
        var dropNextWord = false

        init(scalars: [Unicode.Scalar], home: String) {
            self.scalars = scalars
            self.home = home
        }

        func peek(_ offset: Int = 0) -> Unicode.Scalar? {
            index + offset < scalars.count ? scalars[index + offset] : nil
        }

        mutating func read() -> [[Word]]? {
            guard scalars.count <= ShellWords.maxLength else { return nil }
            while let scalar = peek() {
                switch scalar {
                case " ", "\t":
                    endWord()
                    index += 1
                case "\n", ";":
                    endCommand()
                    index += 1
                case "&":
                    if peek(1) == ">" {
                        // `&>file`: redirect both streams.
                        endWord()
                        index += peek(2) == ">" ? 3 : 2
                        dropNextWord = true
                    } else {
                        endCommand()
                        index += peek(1) == "&" ? 2 : 1
                    }
                case "|":
                    endCommand()
                    index += (peek(1) == "|" || peek(1) == "&") ? 2 : 1
                case "(", ")":
                    // A subshell or a function definition.
                    return nil
                case "<", ">":
                    if scalar == "<", peek(1) == "<" { return nil } // here document or here string
                    if scalar == "<", peek(1) == "(" { return nil } // process substitution
                    if scalar == ">", peek(1) == "(" { return nil }
                    // A number right before is the file descriptor: `2>`.
                    if inWord, literal, !text.isEmpty, text.allSatisfy({ ("0"..."9").contains($0) }), String(raw) == String(text) {
                        resetWord()
                    } else {
                        endWord()
                    }
                    index += 1
                    if peek() == ">" || peek() == "&" || peek() == "|" { index += 1 }
                    dropNextWord = true
                case "#" where !inWord:
                    // A comment runs to the end of the line.
                    while let next = peek(), next != "\n" { index += 1 }
                case "'":
                    inWord = true
                    raw.append(scalar)
                    index += 1
                    guard let end = scalars[index...].firstIndex(of: "'") else { return nil }
                    for inner in scalars[index..<end] {
                        text.append(inner)
                        raw.append(inner)
                    }
                    raw.append("'")
                    index = end + 1
                case "\"":
                    inWord = true
                    raw.append(scalar)
                    index += 1
                    guard readDoubleQuoted() else { return nil }
                case "\\":
                    index += 1
                    guard let next = peek() else { return nil }
                    index += 1
                    // A backslash-newline joins lines.
                    if next == "\n" { continue }
                    inWord = true
                    raw.append("\\")
                    raw.append(next)
                    text.append(next)
                case "$":
                    inWord = true
                    guard readDollar() else { return nil }
                case "`":
                    inWord = true
                    guard readBackquoted() else { return nil }
                case "~" where !inWord:
                    inWord = true
                    raw.append(scalar)
                    index += 1
                    // `~` and `~/…` are the home folder; `~user` is not read.
                    if (peek() == nil || peek() == "/" || peek().map(Self.endsWord) == true), !home.isEmpty {
                        text.append(contentsOf: home.unicodeScalars)
                    } else {
                        text.append(scalar)
                        literal = false
                    }
                default:
                    inWord = true
                    if scalar == "*" || scalar == "?" || scalar == "[" || scalar == "{" {
                        // A glob or a brace expansion.
                        literal = false
                    }
                    text.append(scalar)
                    raw.append(scalar)
                    index += 1
                }
            }
            endCommand()
            return commands
        }

        static func endsWord(_ scalar: Unicode.Scalar) -> Bool {
            " \t\n;&|<>()".unicodeScalars.contains(scalar)
        }

        mutating func readDoubleQuoted() -> Bool {
            while let scalar = peek() {
                switch scalar {
                case "\"":
                    raw.append(scalar)
                    index += 1
                    return true
                case "\\":
                    index += 1
                    guard let next = peek() else { return false }
                    index += 1
                    raw.append("\\")
                    raw.append(next)
                    if next == "\n" { continue }
                    // Inside double quotes a backslash escapes only these.
                    if !"$`\"\\".unicodeScalars.contains(next) { text.append("\\") }
                    text.append(next)
                case "$":
                    guard readDollar() else { return false }
                case "`":
                    guard readBackquoted() else { return false }
                default:
                    text.append(scalar)
                    raw.append(scalar)
                    index += 1
                }
            }
            return false
        }

        /// `$HOME` and `${HOME}` expand; any other expansion makes the word
        /// not literal. `$(…)` is kept whole in `raw`.
        mutating func readDollar() -> Bool {
            let start = index
            index += 1
            switch peek() {
            case "(":
                var depth = 0
                var quote: Unicode.Scalar?
                while let scalar = peek() {
                    index += 1
                    if let open = quote {
                        if scalar == open { quote = nil }
                        continue
                    }
                    switch scalar {
                    case "'", "\"": quote = scalar
                    case "(": depth += 1
                    case ")":
                        depth -= 1
                        if depth == 0 {
                            appendRaw(from: start)
                            literal = false
                            return true
                        }
                    default: break
                    }
                }
                return false
            case "{":
                guard let end = scalars[index...].firstIndex(of: "}") else { return false }
                let name = String(String.UnicodeScalarView(scalars[(index + 1)..<end]))
                index = end + 1
                appendRaw(from: start)
                expand(name)
                return true
            default:
                var name = String.UnicodeScalarView()
                while let scalar = peek(), scalar.isASCII,
                      scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) || scalar == "_" {
                    name.append(scalar)
                    index += 1
                }
                if name.isEmpty {
                    if let special = peek(), "@*#?$!-0123456789".unicodeScalars.contains(special) {
                        // A special parameter: `$?`, `$1`, `$@`…
                        index += 1
                        appendRaw(from: start)
                        literal = false
                    } else if peek() == "'" || peek() == "\"" {
                        // `$'…'` and `$"…"` quoting: escapes or translation
                        // this reader does not apply.
                        raw.append("$")
                        literal = false
                    } else {
                        // A lone `$` is just a dollar sign.
                        text.append("$")
                        raw.append("$")
                    }
                    return true
                }
                appendRaw(from: start)
                expand(String(name))
                return true
            }
        }

        mutating func expand(_ name: String) {
            if name == "HOME", !home.isEmpty {
                text.append(contentsOf: home.unicodeScalars)
            } else {
                literal = false
            }
        }

        mutating func readBackquoted() -> Bool {
            let start = index
            index += 1
            guard let end = scalars[index...].firstIndex(of: "`") else { return false }
            index = end + 1
            appendRaw(from: start)
            literal = false
            return true
        }

        mutating func appendRaw(from start: Int) {
            raw.append(contentsOf: scalars[start..<index])
        }

        mutating func resetWord() {
            text = String.UnicodeScalarView()
            raw = String.UnicodeScalarView()
            literal = true
            inWord = false
        }

        mutating func endWord() {
            guard inWord else { return }
            if dropNextWord {
                dropNextWord = false
            } else {
                words.append(Word(text: String(text), raw: String(raw), isLiteral: literal))
            }
            resetWord()
        }

        mutating func endCommand() {
            endWord()
            dropNextWord = false
            commands.append(words)
            words = []
        }
    }
}
