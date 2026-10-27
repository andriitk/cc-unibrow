import Foundation
import Testing
@testable import UnibrowCore

@Suite("Wire protocol")
struct ProtocolTests {
    @Test("Frames are single-line JSON terminated by a newline")
    func framing() throws {
        let message = HookMessage(event: .permissionRequest, payload: .object(["text": .string("a\nb")]))
        let frame = try WireProtocol.frame(message)

        #expect(frame.last == WireProtocol.delimiter)
        #expect(frame.dropLast().contains(WireProtocol.delimiter) == false)

        let decoded = try WireProtocol.unframe(HookMessage.self, from: frame.dropLast())
        #expect(decoded == message)
    }

    @Test("Every decision survives a round trip", arguments: [
        Decision.allow,
        .allowAlways(updatedPermissions: [.object(["type": .string("addRules")])]),
        .deny(message: "nope", interrupt: true),
        .answerElicitation(.accept(content: ["name": .string("a"), "n": .number(3), "ok": .bool(true)])),
        .answerElicitation(.accept(content: [:])),
        .answerElicitation(.decline),
        .answerElicitation(.cancel),
        .passthrough,
    ])
    func decisionRoundTrip(decision: Decision) throws {
        let frame = try WireProtocol.frame(DecisionMessage(decision: decision))
        let decoded = try WireProtocol.unframe(DecisionMessage.self, from: frame.dropLast())
        #expect(decoded.decision == decision)
    }

    @Test("The form's property order travels with the message; old messages decode without it")
    func propertyOrder() throws {
        let message = HookMessage(event: .elicitation, payload: .object([:]), propertyOrder: ["b", "a"])
        let frame = try WireProtocol.frame(message)
        #expect(try WireProtocol.unframe(HookMessage.self, from: frame.dropLast()).propertyOrder == ["b", "a"])
        let old = Data(#"{"event":"PermissionRequest","payload":{},"version":1}"#.utf8)
        #expect(try WireProtocol.unframe(HookMessage.self, from: old).propertyOrder == nil)
    }

    @Test("Blocking events wait for an answer; alerts carry session details")
    func eventKinds() {
        #expect(HookEvent.elicitation.expectsDecision)
        #expect(!HookEvent.stopFailure.expectsDecision)
        #expect(!HookEvent.notification.expectsDecision)
        #expect(HookEvent.stopFailure.needsSessionDetails)
        #expect(HookEvent.notification.needsSessionDetails)
        #expect(!HookEvent.postToolUse.needsSessionDetails)
    }

    @Test("Unknown payload fields are preserved")
    func payloadKeepsUnknownFields() throws {
        let payload = Fixtures.payload(#"{"session_id":"s","future_field":{"x":[1,true,null]}}"#)
        #expect(payload.raw["future_field"]?["x"] == .array([.number(1), .bool(true), .null]))
    }

    @Test("A non-object payload is rejected")
    func payloadMustBeObject() {
        #expect(throws: HookPayloadError.notAnObject) {
            try HookPayload(data: Data("[1,2]".utf8))
        }
    }
}

@Suite("Claude Code hook output")
struct HookOutputTests {
    private func json(_ decision: Decision) throws -> String? {
        try HookOutput.permissionRequest(decision).map { String(decoding: try $0.encoded(), as: UTF8.self) }
    }

    @Test func allow() throws {
        #expect(try json(.allow) == #"{"hookSpecificOutput":{"decision":{"behavior":"allow"},"hookEventName":"PermissionRequest"}}"#)
    }

    @Test func denyWithInterrupt() throws {
        #expect(try json(.deny(message: "Denied", interrupt: true))
            == #"{"hookSpecificOutput":{"decision":{"behavior":"deny","interrupt":true,"message":"Denied"},"hookEventName":"PermissionRequest"}}"#)
    }

    @Test("Always allow forwards Claude Code's suggestions as updatedPermissions")
    func allowAlways() throws {
        let suggestions = Fixtures.bashRequest.permissionSuggestions
        let output = try #require(HookOutput.permissionRequest(.allowAlways(updatedPermissions: suggestions)))
        #expect(output["hookSpecificOutput"]?["decision"]?["updatedPermissions"] == .array(suggestions))
    }

    @Test("Always allow without suggestions degrades to a plain allow")
    func allowAlwaysWithoutSuggestions() throws {
        #expect(try json(.allowAlways(updatedPermissions: [])) == (try json(.allow)))
    }

    @Test("Passthrough prints nothing, so Claude Code asks in the terminal")
    func passthrough() {
        #expect(HookOutput.permissionRequest(.passthrough) == nil)
        #expect(HookOutput.elicitation(.passthrough) == nil)
    }

    private func elicitationJSON(_ answer: ElicitationAnswer) throws -> String? {
        try HookOutput.output(for: .elicitation, .answerElicitation(answer))
            .map { String(decoding: try $0.encoded(), as: UTF8.self) }
    }

    @Test("Elicitation accept carries the content keyed by property name")
    func elicitationAccept() throws {
        #expect(try elicitationJSON(.accept(content: ["count": .number(3), "name": .string("alice"), "ok": .bool(false)]))
            == #"{"hookSpecificOutput":{"action":"accept","content":{"count":3,"name":"alice","ok":false},"hookEventName":"Elicitation"}}"#)
    }

    @Test("Elicitation accept without fields (a URL) has no content")
    func elicitationAcceptURL() throws {
        #expect(try elicitationJSON(.accept(content: [:]))
            == #"{"hookSpecificOutput":{"action":"accept","hookEventName":"Elicitation"}}"#)
    }

    @Test func elicitationDeclineAndCancel() throws {
        #expect(try elicitationJSON(.decline) == #"{"hookSpecificOutput":{"action":"decline","hookEventName":"Elicitation"}}"#)
        #expect(try elicitationJSON(.cancel) == #"{"hookSpecificOutput":{"action":"cancel","hookEventName":"Elicitation"}}"#)
    }

    @Test("A decision for the wrong event prints nothing")
    func mismatchedDecisions() {
        #expect(HookOutput.output(for: .permissionRequest, .answerElicitation(.decline)) == nil)
        #expect(HookOutput.output(for: .elicitation, .allow) == nil)
        #expect(HookOutput.output(for: .stop, .allow) == nil)
    }
}
