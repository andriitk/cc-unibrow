import Foundation
import Testing
@testable import UnibrowCore

@Suite("MCP elicitation")
struct ElicitationTests {
    static let formPayloadJSON = """
    {"session_id":"s1","cwd":"/p/shop","hook_event_name":"Elicitation","mcp_server_name":"tracker",
     "message":"Pick a project","mode":"form","elicitation_id":"e1",
     "requested_schema":{"type":"object","properties":{
       "zeta":{"type":"string","title":"Name","minLength":2,"maxLength":5,"default":"ab"},
       "email":{"type":"string","format":"email"},
       "count":{"type":"integer","minimum":1,"maximum":5,"default":2},
       "ratio":{"type":"number","maximum":1.5},
       "agree":{"type":"boolean","default":true},
       "color":{"type":"string","enum":["r","g"],"enumNames":["Red","Green"]},
       "size":{"type":"string","oneOf":[{"const":"s","title":"Small"},{"const":"l","title":"Large"}],"default":"l"},
       "tags":{"type":"array","items":{"type":"string","enum":["a","b","c"]},"minItems":1,"maxItems":2},
       "api_token":{"type":"string","description":"Your token"}
     },"required":["zeta","color"]}}
    """

    static var formPayload: HookPayload { Fixtures.payload(formPayloadJSON) }

    private func form(_ schema: String, order: [String]? = nil) throws -> ElicitationForm {
        try ElicitationForm.parse(JSONValue(data: Data(schema.utf8)), propertyOrder: order).get()
    }

    // MARK: Payload

    @Test("A form payload decodes with every field kind")
    func decodesForm() throws {
        let order = JSONKeyOrder.keys(in: Data(Self.formPayloadJSON.utf8), at: ["requested_schema", "properties"])
        let request = try #require(PendingRequest(elicitationPayload: Self.formPayload, propertyOrder: order))
        let elicitation = try #require(request.elicitation)
        #expect(request.sessionID == "s1")
        #expect(request.toolName == "Elicitation")
        #expect(!request.isQuestion)
        #expect(elicitation.serverName == "tracker")
        #expect(elicitation.message == "Pick a project")
        #expect(elicitation.elicitationID == "e1")
        guard case .form(let form) = elicitation.content else {
            Issue.record("Expected a form")
            return
        }
        // The server's order, not alphabetical.
        #expect(form.fields.map(\.name) == ["zeta", "email", "count", "ratio", "agree", "color", "size", "tags", "api_token"])
        let byName = Dictionary(uniqueKeysWithValues: form.fields.map { ($0.name, $0) })
        #expect(byName["zeta"]?.kind == .text(format: nil, minLength: 2, maxLength: 5))
        #expect(byName["zeta"]?.title == "Name")
        #expect(byName["zeta"]?.isRequired == true)
        #expect(byName["email"]?.kind == .text(format: .email, minLength: nil, maxLength: nil))
        #expect(byName["email"]?.title == "email")
        #expect(byName["count"]?.kind == .number(integer: true, minimum: 1, maximum: 5))
        #expect(byName["ratio"]?.kind == .number(integer: false, minimum: nil, maximum: 1.5))
        #expect(byName["agree"]?.kind == .boolean)
        #expect(byName["color"]?.kind == .choice(
            options: [.init(value: "r", title: "Red"), .init(value: "g", title: "Green")],
            multiple: false, minItems: nil, maxItems: nil
        ))
        #expect(byName["size"]?.kind == .choice(
            options: [.init(value: "s", title: "Small"), .init(value: "l", title: "Large")],
            multiple: false, minItems: nil, maxItems: nil
        ))
        #expect(byName["tags"]?.kind == .choice(
            options: ["a", "b", "c"].map { .init(value: $0, title: $0) },
            multiple: true, minItems: 1, maxItems: 2
        ))
        #expect(byName["api_token"]?.isSensitive == true)
        #expect(byName["api_token"]?.description == "Your token")
        #expect(byName["email"]?.isSensitive == false)
    }

    @Test("Defaults fill the starting values")
    func defaults() throws {
        guard case .form(let form)? = ElicitationRequest(payload: Self.formPayload)?.content else {
            Issue.record("Expected a form")
            return
        }
        let values = form.initialValues
        #expect(values["zeta"] == .text("ab"))
        #expect(values["count"] == .text("2"))
        #expect(values["agree"] == .flag(true))
        #expect(values["size"] == .choices(["l"]))
        #expect(values["color"] == .choices([]))
        #expect(values["email"] == .text(""))
    }

    @Test("Without the server's order, required fields come first, then alphabetical")
    func fallbackOrder() throws {
        let form = try form(#"{"type":"object","properties":{"b":{"type":"string"},"z":{"type":"string"},"a":{"type":"string"}},"required":["z"]}"#)
        #expect(form.fields.map(\.name) == ["z", "a", "b"])
    }

    @Test("A URL payload decodes; mode defaults to form")
    func decodesURLAndDefaultMode() throws {
        let url = Fixtures.payload(#"{"session_id":"s","mcp_server_name":"auth","message":"Sign in","mode":"url","url":"https://auth.example.com/login","elicitation_id":"x"}"#)
        guard case .url(let link)? = ElicitationRequest(payload: url)?.content else {
            Issue.record("Expected a URL")
            return
        }
        #expect(link.host == "auth.example.com")

        let noMode = Fixtures.payload(#"{"session_id":"s","mcp_server_name":"a","message":"m","requested_schema":{"type":"object","properties":{"n":{"type":"string"}}}}"#)
        guard case .form? = ElicitationRequest(payload: noMode)?.content else {
            Issue.record("Expected a form")
            return
        }
    }

    @Test("Not an elicitation, or no session: no request")
    func rejectsOtherPayloads() {
        #expect(ElicitationRequest(payload: Fixtures.bashRequest) == nil)
        #expect(PendingRequest(elicitationPayload: Fixtures.payload(#"{"mcp_server_name":"a","message":"m"}"#)) == nil)
    }

    @Test("Unusable requests go to the terminal", arguments: [
        #"{"session_id":"s","mcp_server_name":"a","message":"m","mode":"url"}"#,
        #"{"session_id":"s","mcp_server_name":"a","message":"m","mode":"carrier-pigeon"}"#,
        #"{"session_id":"s","mcp_server_name":"a","message":"m","requested_schema":{"type":"array"}}"#,
    ])
    func unsupportedRequests(json: String) throws {
        let request = try #require(ElicitationRequest(payload: Fixtures.payload(json)))
        guard case .unsupported = request.content else {
            Issue.record("Expected unsupported, got \(request.content)")
            return
        }
    }

    // MARK: Schema

    @Test("Schemas the notch cannot render are unsupported", arguments: [
        #"{"type":"object","properties":{"o":{"type":"object"}}}"#,
        #"{"type":"object","properties":{"l":{"type":"array","items":{"type":"number"}}}}"#,
        #"{"type":"object","properties":{"n":{"type":"null"}}}"#,
        #"{"type":"object","properties":{"x":{}}}"#,
        #"{"type":"object","properties":{"x":"string"}}"#,
        #"{"type":"object","properties":{"e":{"type":"string","enum":[1,2]}}}"#,
        #"{"type":"object","properties":{"e":{"type":"string","oneOf":[{"title":"no const"}]}}}"#,
        #"{"type":"object","properties":[]}"#,
        #"{"type":"string"}"#,
        #"[1]"#,
    ])
    func unsupportedSchemas(schema: String) throws {
        let result = ElicitationForm.parse(try JSONValue(data: Data(schema.utf8)))
        #expect(throws: ElicitationForm.UnsupportedSchema.self) { try result.get() }
    }

    @Test("Too many fields or options are unsupported")
    func limits() throws {
        let fields = (0...ElicitationForm.maxFields).map { "\"f\($0)\":{\"type\":\"string\"}" }.joined(separator: ",")
        #expect(throws: ElicitationForm.UnsupportedSchema.self) {
            try form("{\"type\":\"object\",\"properties\":{\(fields)}}")
        }
        let options = (0...ElicitationForm.maxOptions).map { "\"o\($0)\"" }.joined(separator: ",")
        #expect(throws: ElicitationForm.UnsupportedSchema.self) {
            try form("{\"type\":\"object\",\"properties\":{\"e\":{\"type\":\"string\",\"enum\":[\(options)]}}}")
        }
    }

    @Test("An empty form is fine: Submit sends an empty content")
    func emptyForm() throws {
        let form = try form(#"{"type":"object","properties":{}}"#)
        #expect(form.fields.isEmpty)
        #expect(form.content(for: form.initialValues) == [:])
        #expect(try self.form(#"{}"#).fields.isEmpty)
    }

    @Test("Sensitive fields are detected by name, title or format", arguments: [
        ("password", nil, nil, true),
        ("db", "Database Password", nil, true),
        ("x", nil, "password", true),
        ("GITHUB_TOKEN", nil, nil, true),
        ("client_secret", nil, nil, true),
        ("key", "API key", nil, true),
        ("username", "User name", nil, false),
        ("email", nil, "email", false),
    ] as [(String, String?, String?, Bool)])
    func sensitive(name: String, title: String?, format: String?, expected: Bool) {
        #expect(ElicitationField.isSensitive(name: name, title: title, format: format) == expected)
    }

    // MARK: Validation

    @Test("Valid values become content; empty optional fields are left out")
    func validContent() throws {
        guard case .form(let form)? = ElicitationRequest(payload: Self.formPayload)?.content else {
            Issue.record("Expected a form")
            return
        }
        var values = form.initialValues
        values["color"] = .choices(["g"])
        values["tags"] = .choices(["b", "a"])
        values["email"] = .text("me@example.com")
        values["ratio"] = .text(" 0.5 ")
        let content = try #require(form.content(for: values))
        #expect(content == [
            "zeta": .string("ab"),
            "email": .string("me@example.com"),
            "count": .number(2),
            "ratio": .number(0.5),
            "agree": .bool(true),
            "color": .string("g"),
            "size": .string("l"),
            "tags": .array([.string("a"), .string("b")]),
        ])
        #expect(form.errors(for: values).isEmpty)
    }

    @Test("Invalid values are reported per field and block the content")
    func invalidContent() throws {
        guard case .form(let form)? = ElicitationRequest(payload: Self.formPayload)?.content else {
            Issue.record("Expected a form")
            return
        }
        var values = form.initialValues
        values["zeta"] = .text("a")
        values["email"] = .text("not an email")
        values["count"] = .text("2.5")
        values["ratio"] = .text("2")
        values["tags"] = .choices(["a", "b", "c"])
        let errors = form.errors(for: values)
        #expect(errors["zeta"] == "At least 2 characters")
        #expect(errors["email"] == "Not a valid email address")
        #expect(errors["count"] == "Must be a whole number")
        #expect(errors["ratio"] == "Must be at most 1.5")
        #expect(errors["color"] == "Required")
        #expect(errors["tags"] == "Choose at most 2")
        #expect(form.content(for: values) == nil)
    }

    @Test("Field rules", arguments: [
        (#"{"type":"string","maxLength":3}"#, ElicitationValue.text("abcd"), false, "At most 3 characters"),
        (#"{"type":"string","format":"uri"}"#, .text("https://example.com/a"), false, nil),
        (#"{"type":"string","format":"uri"}"#, .text("example com"), false, "Not a valid URL"),
        (#"{"type":"string","format":"date"}"#, .text("2026-02-28"), false, nil),
        (#"{"type":"string","format":"date"}"#, .text("2026-02-30"), false, "Use the format YYYY-MM-DD"),
        (#"{"type":"string","format":"date-time"}"#, .text("2026-10-27T10:00:00Z"), false, nil),
        (#"{"type":"string","format":"date-time"}"#, .text("2026-10-27T10:00:00.250+02:00"), false, nil),
        (#"{"type":"string","format":"date-time"}"#, .text("yesterday"), false, "Use the format YYYY-MM-DDThh:mm:ssZ"),
        (#"{"type":"number","minimum":0}"#, .text("-1"), false, "Must be at least 0"),
        (#"{"type":"number"}"#, .text("abc"), false, "Not a number"),
        (#"{"type":"number"}"#, .text("inf"), false, "Not a number"),
        (#"{"type":"boolean"}"#, .flag(nil), true, "Required"),
        (#"{"type":"boolean"}"#, .flag(nil), false, nil),
        (#"{"type":"string","enum":["a"]}"#, .choices(["zzz"]), false, "Not one of the options"),
        (#"{"type":"array","items":{"anyOf":[{"const":"a","title":"A"}]},"minItems":1}"#, .choices([]), false, "Choose at least 1"),
        (#"{"type":"array","items":{"enum":["a"]}}"#, .choices([]), true, "Required"),
        (#"{"type":"string"}"#, .text(""), true, "Required"),
    ] as [(String, ElicitationValue, Bool, String?)])
    func fieldRules(schema: String, value: ElicitationValue, required: Bool, error: String?) throws {
        let json = "{\"type\":\"object\",\"properties\":{\"f\":\(schema)}\(required ? ",\"required\":[\"f\"]" : "")}"
        let form = try form(json)
        #expect(form.errors(for: ["f": value])["f"] == error)
    }

    @Test("Values are sent exactly; titles are only for display")
    func exactValues() throws {
        let form = try form(#"{"type":"object","properties":{"c":{"type":"string","oneOf":[{"const":"a‮b","title":"Nice‮title"}]}}}"#)
        guard case .choice(let options, _, _, _) = form.fields[0].kind else {
            Issue.record("Expected a choice")
            return
        }
        #expect(options[0].title == "Nice\\u{202E}title")
        #expect(form.content(for: ["c": .choices(["a\u{202E}b"])]) == ["c": .string("a\u{202E}b")])
    }

    // MARK: Escaping

    @Test("Server strings are escaped and capped")
    func escaping() throws {
        let long = String(repeating: "x", count: ElicitationRequest.maxMessageLength + 10)
        let payload = Fixtures.payload("""
        {"session_id":"s","mcp_server_name":"evil\\u001b[2Jserver","message":"Approve\\rDeny\\n\(long)",
         "requested_schema":{"type":"object","properties":{"f":{"type":"string","title":"A\\u200Bb","description":"d\\u202Ee"}}}}
        """)
        let request = try #require(ElicitationRequest(payload: payload))
        #expect(request.serverName == "evil\\u{1B}[2Jserver")
        #expect(request.message.hasPrefix("Approve\\rDeny\n"))
        #expect(request.hasEscapedCharacters)
        #expect(request.isMessageTruncated)
        guard case .form(let form) = request.content else {
            Issue.record("Expected a form")
            return
        }
        #expect(form.fields[0].title == "A\\u{200B}b")
        #expect(form.fields[0].description == "d\\u{202E}e")
    }

    // MARK: URL

    @Test("Display parts come from the parsed URL")
    func linkParts() throws {
        let link = try #require(ElicitationLink("https://accounts.example.com:8443/path?q=1#top"))
        #expect(link.prefix == "https://")
        #expect(link.host == "accounts.example.com")
        #expect(link.suffix == ":8443/path?q=1#top")
        #expect(!link.hasUserInfo)
        #expect(link.isWeb && link.isEncrypted)
        #expect(link.openableURL?.absoluteString == "https://accounts.example.com:8443/path?q=1#top")
    }

    @Test("A backslash cannot show one host and open another")
    func backslash() throws {
        let link = try #require(ElicitationLink(#"https://good.com\@evil.com"#))
        #expect(link.host == "evil.com")
        #expect(link.hasUserInfo)
        #expect(link.refusal == .ambiguous)
        #expect(link.openableURL == nil)
    }

    @Test("User info is shown, the real host highlighted, and the link not opened")
    func userInfo() throws {
        let link = try #require(ElicitationLink("https://good.com@evil.com/login"))
        #expect(link.prefix == "https://good.com@")
        #expect(link.host == "evil.com")
        #expect(link.hasUserInfo)
        #expect(link.refusal == .userInfo)
        #expect(link.openableURL == nil)

        let password = try #require(ElicitationLink("https://u:secret@evil.com/"))
        #expect(password.prefix == "https://u:•••@")
        #expect(password.refusal == .userInfo)
    }

    @Test("An @ in the fragment is not user info: the host shown is the host opened")
    func fragmentAt() throws {
        let link = try #require(ElicitationLink("https://evil.com#@good.com"))
        #expect(link.host == "evil.com")
        #expect(link.suffix == "#@good.com")
        #expect(!link.hasUserInfo)
        #expect(link.openableURL?.host() == "evil.com")
    }

    @Test("A percent-encoded host is shown encoded and not opened")
    func encodedHost() throws {
        let link = try #require(ElicitationLink("https://%65vil.com/"))
        #expect(link.host == "%65vil.com")
        #expect(link.refusal == .encodedHost)
        #expect(link.openableURL == nil)
    }

    @Test("An international host is shown as punycode and flagged")
    func homograph() throws {
        let link = try #require(ElicitationLink("https://\u{0430}pple.com/x"))
        #expect(link.host == "xn--pple-43d.com")
        #expect(link.unicodeHost == "\u{0430}pple.com")
        #expect(link.hasInternationalHost)
        #expect(link.openableURL?.absoluteString == "https://xn--pple-43d.com/x")

        let puny = try #require(ElicitationLink("https://xn--pple-43d.com/"))
        #expect(puny.hasInternationalHost)
        #expect(puny.host == "xn--pple-43d.com")
    }

    @Test("Plain HTTP opens but is marked; hidden characters are escaped and refused")
    func otherFlags() throws {
        let plain = try #require(ElicitationLink("http://example.com"))
        #expect(plain.isWeb && !plain.isEncrypted)
        #expect(plain.suffix.isEmpty)

        let hidden = try #require(ElicitationLink("https://example.com/\u{202E}gpj.exe"))
        #expect(hidden.refusal == .ambiguous)
        #expect(hidden.openableURL == nil)

        let ipv6 = try #require(ElicitationLink("https://[::1]:8080/x"))
        #expect(ipv6.host == "[::1]")
    }

    @Test("Only unambiguous web links open from the notch", arguments: [
        "file:///etc/passwd", "javascript:alert(1)", "vscode://ext/install", "https://", "mailto:a@b.c",
        "https://example.com/a b", "ftp://example.com/",
    ])
    func nonWebLinks(raw: String) throws {
        let link = try #require(ElicitationLink(raw))
        #expect(!link.isWeb)
        #expect(link.refusal != nil)
        #expect(link.openableURL == nil)
    }

    @Test("A very long URL is shortened for display only")
    func longLink() throws {
        let raw = "https://example.com/" + String(repeating: "a", count: 5_000)
        let link = try #require(ElicitationLink(raw))
        #expect(link.isTruncated)
        #expect(link.raw == raw)
        #expect(link.openableURL?.absoluteString == raw)
    }

    @Test("An empty URL is no link")
    func emptyLink() {
        #expect(ElicitationLink("  ") == nil)
    }
}

@Suite("JSON key order")
struct JSONKeyOrderTests {
    @Test("Reads keys in document order at a path")
    func order() {
        let json = #"{"a":1,"requested_schema":{"x":[1,{"z":2}],"properties":{"zeta":{"type":"string","p":{"q":"}"}},"alpha":{},"mé":true}},"properties":{"wrong":1}}"#
        #expect(JSONKeyOrder.keys(in: Data(json.utf8), at: ["requested_schema", "properties"]) == ["zeta", "alpha", "mé"])
        #expect(JSONKeyOrder.keys(in: Data(json.utf8), at: []) == ["a", "requested_schema", "properties"])
    }

    @Test("Missing paths and broken JSON give nil", arguments: [
        #"{"requested_schema":{"type":"object"}}"#,
        #"{"requested_schema":"x"}"#,
        #"{"requested_schema":{"properties":{"a":1"#,
        #"[1,2]"#,
        "",
    ])
    func missing(json: String) {
        #expect(JSONKeyOrder.keys(in: Data(json.utf8), at: ["requested_schema", "properties"]) == nil)
    }

    @Test("Escaped quotes inside strings do not end them")
    func escapes() {
        let json = #"{"p":{"a\"b":"x\"}y","c":1}}"#
        #expect(JSONKeyOrder.keys(in: Data(json.utf8), at: ["p"]) == ["a\"b", "c"])
    }
}
