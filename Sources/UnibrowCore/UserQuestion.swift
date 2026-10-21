import Foundation

/// A question Claude asks through the `AskUserQuestion` tool.
///
/// Claude Code routes this tool through the permission flow: the terminal
/// prompt *is* the question form. Answering it from the notch means allowing
/// the tool with `updatedInput` that carries an `answers` map
/// (`question text → chosen label`), which is what the terminal form produces.
public struct UserQuestion: Sendable, Hashable, Identifiable {
    public struct Option: Sendable, Hashable {
        public let label: String
        public let description: String?
    }

    public let question: String
    public let header: String?
    public let allowsMultipleAnswers: Bool
    public let options: [Option]

    public var id: String { question }

    public static let toolName = "AskUserQuestion"

    /// Parses the `questions` array of an `AskUserQuestion` tool input.
    /// Returns `nil` if the input does not look like one.
    public static func parse(_ input: JSONValue) -> [UserQuestion]? {
        guard let items = input["questions"]?.arrayValue, !items.isEmpty else { return nil }
        let questions = items.compactMap { item -> UserQuestion? in
            guard let question = item["question"]?.stringValue else { return nil }
            let options = (item["options"]?.arrayValue ?? []).compactMap { option -> Option? in
                guard let label = option["label"]?.stringValue else { return nil }
                return Option(label: label, description: option["description"]?.stringValue)
            }
            return UserQuestion(
                question: question,
                header: item["header"]?.stringValue,
                allowsMultipleAnswers: item["multiSelect"]?.boolValue ?? false,
                options: options
            )
        }
        return questions.count == items.count ? questions : nil
    }

    /// The tool input with the user's answers merged in.
    ///
    /// - Parameter answers: chosen labels per question text. Multiple choices
    ///   are joined with ", ".
    public static func answeredInput(_ input: JSONValue, answers: [String: [String]]) -> JSONValue {
        var object = input.objectValue ?? [:]
        object["answers"] = .object(answers.mapValues { .string($0.joined(separator: ", ")) })
        return .object(object)
    }
}
