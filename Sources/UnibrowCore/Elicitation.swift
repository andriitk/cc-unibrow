public import Foundation

/// An MCP server asking the user for input through Claude Code's
/// `Elicitation` hook: a small form, or a URL to open (usually a sign-in).
///
/// Everything here comes from the MCP server, which is untrusted: the server
/// name, the message, field titles, descriptions, option titles and the URL.
/// Text meant for display is escaped like `ToolSummary` escapes tool input
/// (control, bidi and invisible characters become `\u{…}`) and capped.
/// Values sent back (property names, option values) stay exact.
///
/// See https://code.claude.com/docs/en/hooks#elicitation and the MCP
/// elicitation specification for the schema subset a form may use.
public struct ElicitationRequest: Sendable, Hashable {
    public enum Content: Sendable, Hashable {
        /// Form mode with a schema the notch can render.
        case form(ElicitationForm)
        /// URL mode: open a link in the browser.
        case url(ElicitationLink)
        /// Something the notch cannot show faithfully; answer in the terminal.
        case unsupported(reason: String)
    }

    /// Display name of the MCP server (escaped).
    public let serverName: String
    /// The server's message (escaped, capped).
    public let message: String
    /// The server name or the message had characters that are shown escaped.
    public let hasEscapedCharacters: Bool
    /// The message was longer than the card shows.
    public let isMessageTruncated: Bool
    public let elicitationID: String?
    public let content: Content

    static let maxMessageLength = 2_000
    static let maxLabelLength = 200

    public init(serverName: String, message: String, elicitationID: String? = nil, content: Content) {
        let name = Self.display(serverName, limit: 80)
        let text = Self.display(message, limit: Self.maxMessageLength)
        self.serverName = name.text
        self.message = text.text
        self.hasEscapedCharacters = name.escaped || text.escaped
        self.isMessageTruncated = text.truncated
        self.elicitationID = elicitationID
        self.content = content
    }

    /// Reads an `Elicitation` hook payload. Returns `nil` only when it is not
    /// one at all; a request the notch cannot render becomes `.unsupported`.
    ///
    /// - Parameter propertyOrder: the form's property names in the order the
    ///   server wrote them (JSON objects lose their order once decoded).
    public init?(payload: HookPayload, propertyOrder: [String]? = nil) {
        guard let server = payload.raw["mcp_server_name"]?.stringValue else { return nil }
        let message = payload.raw["message"]?.stringValue ?? ""
        let mode = payload.raw["mode"]?.stringValue ?? "form"
        let content: Content
        switch mode {
        case "form":
            switch ElicitationForm.parse(payload.raw["requested_schema"] ?? .object([:]), propertyOrder: propertyOrder) {
            case .success(let form): content = .form(form)
            case .failure(let error): content = .unsupported(reason: error.reason)
            }
        case "url":
            if let raw = payload.raw["url"]?.stringValue, let link = ElicitationLink(raw) {
                content = .url(link)
            } else {
                content = .unsupported(reason: "The server sent no usable URL.")
            }
        default:
            content = .unsupported(reason: "Unknown request type.")
        }
        self.init(
            serverName: server,
            message: message,
            elicitationID: payload.raw["elicitation_id"]?.stringValue,
            content: content
        )
    }

    /// Escapes and caps untrusted text for display.
    static func display(_ text: String, limit: Int) -> (text: String, escaped: Bool, truncated: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let truncated = trimmed.count > limit
        let shown = truncated ? String(trimmed.prefix(limit)) : trimmed
        let result = ToolSummary.escaped(shown)
        return (truncated ? result.text + "…" : result.text, result.changed, truncated)
    }

    static func label(_ text: String) -> String {
        display(ToolSummary.firstLine(of: text), limit: maxLabelLength).text
    }
}

// MARK: - Answer

/// What the user answered. Claude Code forwards it to the MCP server.
public enum ElicitationAnswer: Sendable, Hashable {
    /// Submitted; `content` holds the form values keyed by property name
    /// (empty for a URL request).
    case accept(content: [String: JSONValue])
    /// Explicitly refused.
    case decline
    /// Dismissed without a choice (the terminal dialog's Esc).
    case cancel

    public var action: String {
        switch self {
        case .accept: "accept"
        case .decline: "decline"
        case .cancel: "cancel"
        }
    }
}

// MARK: - Form

/// A form-mode request: a flat object of primitive properties.
public struct ElicitationForm: Sendable, Hashable {
    public let fields: [ElicitationField]

    /// Most forms have a handful of fields; a huge one belongs in the terminal.
    static let maxFields = 25
    static let maxOptions = 100

    public struct UnsupportedSchema: Error, Equatable {
        public let reason: String
    }

    public static func parse(_ schema: JSONValue, propertyOrder: [String]? = nil) -> Result<ElicitationForm, UnsupportedSchema> {
        func unsupported(_ reason: String) -> Result<ElicitationForm, UnsupportedSchema> {
            .failure(UnsupportedSchema(reason: reason))
        }
        guard let root = schema.objectValue else { return unsupported("The form is not an object.") }
        if let type = root["type"], type != .string("object") {
            return unsupported("The form is not an object.")
        }
        let properties: [String: JSONValue]
        switch root["properties"] {
        case nil, .null?: properties = [:]
        case .object(let object)?: properties = object
        default: return unsupported("The form's fields are malformed.")
        }
        guard properties.count <= maxFields else {
            return unsupported("The form has \(properties.count) fields, too many to show here.")
        }
        let required = Set((root["required"]?.arrayValue ?? []).compactMap(\.stringValue))

        var fields: [ElicitationField] = []
        for name in orderedNames(properties.keys, order: propertyOrder, required: root["required"]) {
            guard let property = properties[name] else { continue }
            switch ElicitationField.parse(name: name, schema: property, isRequired: required.contains(name)) {
            case .success(let field): fields.append(field)
            case .failure(let error): return .failure(error)
            }
        }
        return .success(ElicitationForm(fields: fields))
    }

    /// The server's order when known; otherwise required fields in `required`
    /// order, then the rest alphabetically.
    static func orderedNames(_ names: Dictionary<String, JSONValue>.Keys, order: [String]?, required: JSONValue?) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        let preferred = order ?? (required?.arrayValue ?? []).compactMap(\.stringValue)
        for name in preferred where names.contains(name) && !seen.contains(name) {
            result.append(name)
            seen.insert(name)
        }
        result += names.filter { !seen.contains($0) }.sorted()
        return result
    }

    // MARK: Values

    /// The starting values: the schema's defaults, or empty.
    public var initialValues: [String: ElicitationValue] {
        Dictionary(uniqueKeysWithValues: fields.map { ($0.name, $0.initialValue) })
    }

    /// Problems per field name; empty when the form can be submitted.
    public func errors(for values: [String: ElicitationValue]) -> [String: String] {
        var errors: [String: String] = [:]
        for field in fields {
            if case .failure(let error) = field.validate(values[field.name] ?? field.emptyValue) {
                errors[field.name] = error.message
            }
        }
        return errors
    }

    /// The `content` to send back, or `nil` while a value is invalid. Empty
    /// optional fields are left out.
    public func content(for values: [String: ElicitationValue]) -> [String: JSONValue]? {
        var content: [String: JSONValue] = [:]
        for field in fields {
            switch field.validate(values[field.name] ?? field.emptyValue) {
            case .success(let value?): content[field.name] = value
            case .success(nil): break
            case .failure: return nil
            }
        }
        return content
    }
}

/// The value of one form field while the user edits it.
public enum ElicitationValue: Sendable, Hashable {
    /// Text and number fields (numbers are typed as text and parsed).
    case text(String)
    /// A checkbox; `nil` until set when the schema has no default.
    case flag(Bool?)
    /// Selected option values (one for a single choice).
    case choices([String])
}

public struct ElicitationField: Sendable, Hashable, Identifiable {
    public enum TextFormat: String, Sendable, Hashable {
        case email, uri, date
        case dateTime = "date-time"
    }

    public struct Option: Sendable, Hashable {
        /// Sent back exactly as the server defined it.
        public let value: String
        /// Shown to the user (escaped).
        public let title: String
    }

    public enum Kind: Sendable, Hashable {
        case text(format: TextFormat?, minLength: Int?, maxLength: Int?)
        case number(integer: Bool, minimum: Double?, maximum: Double?)
        case boolean
        case choice(options: [Option], multiple: Bool, minItems: Int?, maxItems: Int?)
    }

    /// Property name: the key in `content`, sent back exactly.
    public let name: String
    /// Title to show (escaped); the property name when the schema has none.
    public let title: String
    public let description: String?
    public let isRequired: Bool
    public let kind: Kind
    /// Looks like a password or token: shown as a secure field.
    public let isSensitive: Bool
    let defaultValue: JSONValue?

    public var id: String { name }

    static func parse(name: String, schema: JSONValue, isRequired: Bool) -> Result<ElicitationField, ElicitationForm.UnsupportedSchema> {
        func unsupported(_ why: String) -> Result<ElicitationField, ElicitationForm.UnsupportedSchema> {
            .failure(.init(reason: "The field \(ElicitationRequest.label(name)) \(why)."))
        }
        guard let object = schema.objectValue else { return unsupported("is malformed") }
        let int = { (key: String) -> Int? in
            guard let value = object[key]?.doubleValue, value >= 0, value == value.rounded(), value < 1e9 else { return nil }
            return Int(value)
        }

        let kind: Kind
        let type = object["type"]?.stringValue ?? (object["enum"] != nil || object["oneOf"] != nil ? "string" : nil)
        switch type {
        case "string":
            if object["enum"] != nil || object["oneOf"] != nil || object["anyOf"] != nil {
                guard let options = options(in: object), !options.isEmpty else { return unsupported("has options that cannot be shown") }
                guard options.count <= ElicitationForm.maxOptions else { return unsupported("has too many options") }
                kind = .choice(options: options, multiple: false, minItems: nil, maxItems: nil)
            } else {
                let format = object["format"]?.stringValue.flatMap(TextFormat.init(rawValue:))
                kind = .text(format: format, minLength: int("minLength"), maxLength: int("maxLength"))
            }
        case "number", "integer":
            kind = .number(integer: type == "integer", minimum: object["minimum"]?.doubleValue, maximum: object["maximum"]?.doubleValue)
        case "boolean":
            kind = .boolean
        case "array":
            guard let items = object["items"]?.objectValue,
                  items["type"].map({ $0 == .string("string") }) ?? true,
                  let options = options(in: items), !options.isEmpty
            else { return unsupported("is a list the notch cannot show") }
            guard options.count <= ElicitationForm.maxOptions else { return unsupported("has too many options") }
            kind = .choice(options: options, multiple: true, minItems: int("minItems"), maxItems: int("maxItems"))
        case let other?:
            return unsupported("has the unsupported type \(ElicitationRequest.label(other))")
        case nil:
            return unsupported("has no type")
        }

        let title = object["title"]?.stringValue.map(ElicitationRequest.label).flatMap { $0.isEmpty ? nil : $0 }
        let description = object["description"]?.stringValue
            .map { ElicitationRequest.display($0, limit: 400).text }
            .flatMap { $0.isEmpty ? nil : $0 }
        return .success(ElicitationField(
            name: name,
            title: title ?? ElicitationRequest.label(name),
            description: description,
            isRequired: isRequired,
            kind: kind,
            isSensitive: isSensitive(name: name, title: object["title"]?.stringValue, format: object["format"]?.stringValue),
            defaultValue: object["default"]
        ))
    }

    /// `enum` (+ legacy `enumNames`), or `oneOf` / `anyOf` of `{const, title}`.
    /// `nil` when an option is not a string.
    private static func options(in object: [String: JSONValue]) -> [Option]? {
        if let values = object["enum"]?.arrayValue {
            let strings = values.compactMap(\.stringValue)
            guard strings.count == values.count else { return nil }
            let names = object["enumNames"]?.arrayValue?.compactMap(\.stringValue)
            let titles = names?.count == strings.count ? names! : strings
            return zip(strings, titles).map { Option(value: $0, title: ElicitationRequest.label($1)) }
        }
        guard let choices = (object["oneOf"] ?? object["anyOf"])?.arrayValue else { return nil }
        var options: [Option] = []
        for choice in choices {
            guard let value = choice["const"]?.stringValue else { return nil }
            options.append(Option(value: value, title: ElicitationRequest.label(choice["title"]?.stringValue ?? value)))
        }
        return options
    }

    /// Password, token, secret… in the name, title or a `password` format.
    static func isSensitive(name: String, title: String?, format: String?) -> Bool {
        if format?.lowercased() == "password" { return true }
        let words = ["password", "passwd", "passphrase", "secret", "token", "apikey", "api_key", "api-key",
                     "credential", "private_key", "privatekey", "otp"]
        return [name, title ?? ""].contains { text in
            let lowered = text.lowercased()
            return words.contains { lowered.contains($0) } || lowered.contains("api key")
        }
    }

    // MARK: Values

    var emptyValue: ElicitationValue {
        switch kind {
        case .text, .number: .text("")
        case .boolean: .flag(nil)
        case .choice: .choices([])
        }
    }

    var initialValue: ElicitationValue {
        switch kind {
        case .text:
            return .text(defaultValue?.stringValue ?? "")
        case .number:
            guard let number = defaultValue?.doubleValue, number.isFinite else { return .text("") }
            return .text(Self.format(number))
        case .boolean:
            return .flag(defaultValue?.boolValue ?? (isRequired ? false : nil))
        case .choice(let options, let multiple, _, _):
            let values = Set(options.map(\.value))
            let defaults = multiple
                ? (defaultValue?.arrayValue ?? []).compactMap(\.stringValue)
                : defaultValue?.stringValue.map { [$0] } ?? []
            return .choices(defaults.filter(values.contains))
        }
    }

    /// The JSON value to send (`nil`: leave the field out) or why it is invalid.
    func validate(_ value: ElicitationValue) -> Result<JSONValue?, ValidationError> {
        func fail(_ message: String) -> Result<JSONValue?, ValidationError> { .failure(ValidationError(message: message)) }

        switch (kind, value) {
        case (.text(let format, let minLength, let maxLength), .text(let text)):
            if text.isEmpty { return isRequired ? fail("Required") : .success(nil) }
            if let minLength, text.count < minLength { return fail("At least \(minLength) characters") }
            if let maxLength, text.count > maxLength { return fail("At most \(maxLength) characters") }
            if let format, !Self.matches(text, format: format) {
                let message = switch format {
                case .email: "Not a valid email address"
                case .uri: "Not a valid URL"
                case .date: "Use the format YYYY-MM-DD"
                case .dateTime: "Use the format YYYY-MM-DDThh:mm:ssZ"
                }
                return fail(message)
            }
            return .success(.string(text))

        case (.number(let integer, let minimum, let maximum), .text(let text)):
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return isRequired ? fail("Required") : .success(nil) }
            guard let number = Double(trimmed), number.isFinite else { return fail("Not a number") }
            if integer, number != number.rounded() { return fail("Must be a whole number") }
            if let minimum, number < minimum { return fail("Must be at least \(Self.format(minimum))") }
            if let maximum, number > maximum { return fail("Must be at most \(Self.format(maximum))") }
            return .success(.number(number))

        case (.boolean, .flag(let flag)):
            guard let flag else { return isRequired ? fail("Required") : .success(nil) }
            return .success(.bool(flag))

        case (.choice(let options, let multiple, let minItems, let maxItems), .choices(let chosen)):
            let allowed = Set(options.map(\.value))
            guard chosen.allSatisfy(allowed.contains) else { return fail("Not one of the options") }
            if chosen.isEmpty, !isRequired, (minItems ?? 0) == 0 { return .success(nil) }
            if !multiple {
                guard chosen.count == 1, let only = chosen.first else { return fail(chosen.isEmpty ? "Required" : "Choose one") }
                return .success(.string(only))
            }
            if chosen.isEmpty, isRequired, minItems == nil { return fail("Required") }
            if let minItems, chosen.count < minItems { return fail("Choose at least \(minItems)") }
            if let maxItems, chosen.count > maxItems { return fail("Choose at most \(maxItems)") }
            // Keep the server's option order, not the click order.
            return .success(.array(options.map(\.value).filter(chosen.contains).map(JSONValue.string)))

        default:
            return fail("Invalid value")
        }
    }

    struct ValidationError: Error, Equatable {
        let message: String
    }

    static func format(_ number: Double) -> String {
        number == number.rounded() && abs(number) < 1e15 ? String(Int64(number)) : String(number)
    }

    static func matches(_ text: String, format: TextFormat) -> Bool {
        switch format {
        case .email:
            // Deliberately loose: one @, something before it, a dotted domain, no spaces.
            let parts = text.split(separator: "@", omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty, !text.contains(where: \.isWhitespace) else { return false }
            let domain = parts[1].split(separator: ".", omittingEmptySubsequences: false)
            return domain.count >= 2 && domain.allSatisfy { !$0.isEmpty }
        case .uri:
            guard let url = URL(string: text), let scheme = url.scheme, !scheme.isEmpty else { return false }
            return !text.contains(where: \.isWhitespace)
        case .date:
            return parseDate(text) != nil
        case .dateTime:
            let formatter = ISO8601DateFormatter()
            if formatter.date(from: text) != nil { return true }
            formatter.formatOptions.insert(.withFractionalSeconds)
            return formatter.date(from: text) != nil
        }
    }

    /// `YYYY-MM-DD` that names a real day.
    private static func parseDate(_ text: String) -> DateComponents? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { return nil }
        let components = DateComponents(year: year, month: month, day: day)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        guard components.isValidDate(in: calendar) else { return nil }
        return components
    }
}

// MARK: - URL

/// A URL-mode request's link, split so the card can highlight the host: the
/// part that decides where the browser really goes.
public struct ElicitationLink: Sendable, Hashable {
    /// The exact URL, opened as is.
    public let raw: String
    /// Display parts (escaped): everything before the host, the host, the rest.
    public let prefix: String
    public let host: String
    public let suffix: String
    /// `http` or `https` with a host. Only these open from the notch.
    public let isWeb: Bool
    public let isEncrypted: Bool
    /// `user@` before the host, as in `https://bank.com@evil.example`.
    public let hasUserInfo: Bool
    /// Non-ASCII or punycode (`xn--`) host, which can imitate another name.
    public let hasInternationalHost: Bool
    public let hasEscapedCharacters: Bool
    /// The rest of the URL was cut for display.
    public let isTruncated: Bool

    static let maxSuffixLength = 1_500

    public init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        self.raw = trimmed

        // Split by hand: Foundation would normalize (or reject) exactly the
        // characters we want to show.
        var schemeEnd = trimmed.startIndex
        var host = Substring("")
        var prefix = Substring("")
        var suffix = Substring(trimmed)
        var userInfo = false
        if let colon = trimmed.firstIndex(of: ":"), trimmed[trimmed.index(after: colon)...].hasPrefix("//") {
            schemeEnd = colon
            let authorityStart = trimmed.index(colon, offsetBy: 3)
            let authorityEnd = trimmed[authorityStart...].firstIndex(where: { "/?#\\".contains($0) }) ?? trimmed.endIndex
            let authority = trimmed[authorityStart..<authorityEnd]
            var hostStart = authorityStart
            if let at = authority.lastIndex(of: "@") {
                userInfo = true
                hostStart = trimmed.index(after: at)
            }
            var hostEnd = authorityEnd
            let hostAndPort = trimmed[hostStart..<authorityEnd]
            if !hostAndPort.hasPrefix("["), let portColon = hostAndPort.lastIndex(of: ":") {
                hostEnd = portColon
            } else if hostAndPort.hasPrefix("["), let bracket = hostAndPort.firstIndex(of: "]") {
                hostEnd = trimmed.index(after: bracket)
            }
            prefix = trimmed[..<hostStart]
            host = trimmed[hostStart..<hostEnd]
            suffix = trimmed[hostEnd...]
        }
        let scheme = schemeEnd == trimmed.startIndex ? "" : trimmed[..<schemeEnd].lowercased()

        let shownPrefix = ToolSummary.escaped(String(prefix.prefix(300)))
        let shownHost = ToolSummary.escaped(String(host.prefix(300)))
        let shownSuffix = ToolSummary.escaped(String(suffix.prefix(Self.maxSuffixLength)))
        self.prefix = shownPrefix.text
        self.host = shownHost.text
        self.suffix = shownSuffix.text + (suffix.count > Self.maxSuffixLength ? "…" : "")
        self.isTruncated = suffix.count > Self.maxSuffixLength || prefix.count > 300 || host.count > 300
        self.hasEscapedCharacters = shownPrefix.changed || shownHost.changed || shownSuffix.changed
        self.hasUserInfo = userInfo
        self.hasInternationalHost = !host.unicodeScalars.allSatisfy(\.isASCII)
            || host.lowercased().split(separator: ".").contains { $0.hasPrefix("xn--") }
        self.isEncrypted = scheme == "https"
        self.isWeb = (scheme == "https" || scheme == "http") && !host.isEmpty
            && !trimmed.contains(where: { $0.isWhitespace || $0.isNewline })
            && URL(string: trimmed) != nil
    }

    /// The URL to hand to the browser, when it may be opened from the notch.
    public var openableURL: URL? {
        isWeb ? URL(string: raw) : nil
    }
}
