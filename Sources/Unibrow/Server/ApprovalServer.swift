import Darwin
import Foundation
import os
import UnibrowCore

/// Accepts hook connections on the Unibrow socket.
///
/// Each hook invocation opens one connection and sends one `HookMessage`.
/// Connections that carry a `PermissionRequest` stay open until the app calls
/// `respond(to:with:)`, or until the peer goes away, which is how a request
/// answered in the terminal is noticed: Claude Code ends the hook process, the
/// socket reaches EOF and `.closed` is emitted.
///
/// All mutable state is confined to `queue`, hence `@unchecked Sendable`.
final class ApprovalServer: @unchecked Sendable {
    typealias ConnectionID = UUID

    enum Event: Sendable {
        /// `peerPID` is the hook process, used to find the app the session runs in.
        case message(ConnectionID, HookMessage, peerPID: pid_t?)
        /// A connection waiting for a decision closed before it got one.
        case closed(ConnectionID)
    }

    enum StartError: Error, CustomStringConvertible {
        case alreadyRunning(path: String)
        case socket(UnixSocket.Error)
        case directory(any Error)

        var description: String {
            switch self {
            case .alreadyRunning(let path): "Another Unibrow is already listening on \(path)"
            case .socket(let error): error.description
            case .directory(let error): "Cannot create the support directory: \(error.localizedDescription)"
            }
        }
    }

    let events: AsyncStream<Event>

    private let path: String
    private let queue = DispatchQueue(label: "dev.andriitk.unibrow.server")
    private let continuation: AsyncStream<Event>.Continuation
    private let logger = Logger(subsystem: "dev.andriitk.unibrow", category: "server")

    private var listener: (fd: Int32, source: any DispatchSourceRead)?
    private var connections: [ConnectionID: Connection] = [:]

    /// Upper bound for one message; tool inputs (e.g. a large `Write`) can be big.
    private static let maxMessageBytes = 8 << 20

    private final class Connection {
        let fd: Int32
        let source: any DispatchSourceRead
        let peerPID: pid_t?
        var buffer = Data()
        var awaitingDecision = false

        init(fd: Int32, source: any DispatchSourceRead, peerPID: pid_t?) {
            self.fd = fd
            self.source = source
            self.peerPID = peerPID
        }
    }

    init(path: String = Paths.socketPath()) {
        self.path = path
        (events, continuation) = AsyncStream.makeStream(of: Event.self)
    }

    deinit {
        continuation.finish()
    }

    // MARK: - Lifecycle

    func start() throws(StartError) {
        let directory = URL(filePath: path).deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw .directory(error)
        }

        // A live socket means another instance owns it; never steal it.
        if let probe = try? UnixSocket.connect(path: path) {
            Darwin.close(probe)
            throw .alreadyRunning(path: path)
        }

        let fd: Int32
        do {
            fd = try UnixSocket.listen(path: path)
        } catch {
            throw .socket(error)
        }
        UnixSocket.setNonBlocking(fd)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.setCancelHandler { Darwin.close(fd) }
        queue.sync { listener = (fd, source) }
        source.resume()
        logger.info("Listening on \(self.path, privacy: .public)")
    }

    func stop() {
        queue.sync {
            listener?.source.cancel()
            listener = nil
            for id in Array(connections.keys) { teardown(id) }
        }
        unlink(path)
        continuation.finish()
    }

    // MARK: - Replies

    /// Sends the decision to the waiting hook and closes the connection.
    func respond(to id: ConnectionID, with decision: Decision) {
        queue.async { [self] in
            guard let connection = connections[id] else { return }
            do {
                let frame = try WireProtocol.frame(DecisionMessage(decision: decision))
                try UnixSocket.writeAll(frame, to: connection.fd)
            } catch {
                logger.error("Failed to deliver decision: \(String(describing: error), privacy: .public)")
            }
            teardown(id)
        }
    }

    /// Closes a connection without a decision; the hook falls back to the terminal.
    func drop(_ id: ConnectionID) {
        queue.async { [self] in teardown(id) }
    }

    // MARK: - Queue-confined

    private func acceptPending() {
        guard let listenFD = listener?.fd else { return }
        while true {
            let fd = accept(listenFD, nil, nil)
            guard fd >= 0 else { return } // EAGAIN: drained

            guard UnixSocket.peerUID(of: fd) == getuid() else {
                logger.warning("Rejected a connection from another user")
                Darwin.close(fd)
                continue
            }
            UnixSocket.setNonBlocking(fd)
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

            let id = ConnectionID()
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.readAvailable(id) }
            source.setCancelHandler { Darwin.close(fd) }
            connections[id] = Connection(fd: fd, source: source, peerPID: UnixSocket.peerPID(of: fd))
            source.resume()
        }
    }

    private func readAvailable(_ id: ConnectionID) {
        guard let connection = connections[id] else { return }
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)

        while true {
            let count = chunk.withUnsafeMutableBytes { read(connection.fd, $0.baseAddress, $0.count) }
            if count > 0 {
                guard !connection.awaitingDecision else { continue } // ignore chatter after the message
                connection.buffer.append(contentsOf: chunk[..<count])
                if connection.buffer.count > Self.maxMessageBytes {
                    logger.error("Dropped an oversized message")
                    teardown(id)
                    return
                }
                if let newline = connection.buffer.firstIndex(of: WireProtocol.delimiter) {
                    handleLine(connection.buffer[..<newline], from: id, connection: connection)
                    guard connections[id] != nil else { return }
                }
                continue
            }
            if count == 0 {
                // EOF: the hook exited. If it was still waiting for the user,
                // the prompt was answered somewhere else.
                let wasWaiting = connection.awaitingDecision
                teardown(id)
                if wasWaiting { continuation.yield(.closed(id)) }
                return
            }
            if errno == EINTR { continue }
            if errno != EAGAIN { teardown(id) }
            return
        }
    }

    private func handleLine(_ line: Data, from id: ConnectionID, connection: Connection) {
        guard let message = try? WireProtocol.unframe(HookMessage.self, from: Data(line)) else {
            logger.error("Dropped a malformed message")
            teardown(id)
            return
        }
        guard message.version == WireProtocol.version else {
            logger.error("Unsupported protocol version \(message.version)")
            teardown(id)
            return
        }

        if message.event.expectsDecision {
            connection.awaitingDecision = true
            connection.buffer = Data()
        } else {
            teardown(id)
        }
        continuation.yield(.message(id, message, peerPID: connection.peerPID))
    }

    private func teardown(_ id: ConnectionID) {
        guard let connection = connections.removeValue(forKey: id) else { return }
        connection.source.cancel()
    }
}
