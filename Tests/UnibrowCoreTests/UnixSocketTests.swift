import Darwin
import Foundation
import Testing
@testable import UnibrowCore

@Suite("Unix socket")
struct UnixSocketTests {
    /// Short path: `sun_path` is limited to 104 bytes.
    private func temporarySocketPath() -> String {
        "/tmp/unibrow-test-\(getpid())-\(UInt32.random(in: 0...UInt32.max)).sock"
    }

    @Test("A message and a decision travel over a real socket")
    func roundTrip() throws {
        let path = temporarySocketPath()
        let listener = try UnixSocket.listen(path: path)
        defer { close(listener); unlink(path) }

        let client = try UnixSocket.connect(path: path)
        defer { close(client) }
        let server = accept(listener, nil, nil)
        #expect(server >= 0)
        defer { close(server) }

        #expect(UnixSocket.peerUID(of: server) == getuid())

        let message = HookMessage(event: .permissionRequest, payload: Fixtures.bashRequest.raw)
        try UnixSocket.writeAll(try WireProtocol.frame(message), to: client)
        let received = try #require(try UnixSocket.readLine(from: server))
        #expect(try WireProtocol.unframe(HookMessage.self, from: received) == message)

        let reply = DecisionMessage(decision: .deny(message: "no", interrupt: false))
        try UnixSocket.writeAll(try WireProtocol.frame(reply), to: server)
        let answer = try #require(try UnixSocket.readLine(from: client))
        #expect(try WireProtocol.unframe(DecisionMessage.self, from: answer) == reply)
    }

    @Test("readLine returns nil when the peer closes without answering")
    func peerClosed() throws {
        let path = temporarySocketPath()
        let listener = try UnixSocket.listen(path: path)
        defer { close(listener); unlink(path) }

        let client = try UnixSocket.connect(path: path)
        defer { close(client) }
        close(accept(listener, nil, nil))

        #expect(try UnixSocket.readLine(from: client) == nil)
    }

    @Test("The socket file is private to the user")
    func permissions() throws {
        let path = temporarySocketPath()
        let listener = try UnixSocket.listen(path: path)
        defer { close(listener); unlink(path) }

        var info = stat()
        #expect(stat(path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
    }

    @Test("Connecting without a listener fails instead of hanging")
    func noListener() {
        #expect(throws: UnixSocket.Error.self) {
            try UnixSocket.connect(path: temporarySocketPath())
        }
    }
}
