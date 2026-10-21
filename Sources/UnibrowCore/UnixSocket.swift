public import Darwin
public import Foundation

/// Thin, explicit wrappers over the POSIX socket calls Unibrow needs.
///
/// Network.framework has no peer-credential check for Unix sockets, and the
/// hook relay must start in a few milliseconds, so plain BSD sockets are the
/// simplest correct tool here.
public enum UnixSocket {
    public struct Error: Swift.Error, CustomStringConvertible, Equatable {
        public let operation: String
        public let code: Int32

        public init(_ operation: String, code: Int32 = errno) {
            self.operation = operation
            self.code = code
        }

        public var description: String {
            "\(operation) failed: \(String(cString: strerror(code))) (errno \(code))"
        }
    }

    /// Creates a listening socket at `path`, replacing a stale socket file.
    /// The socket is only reachable by the current user (`0600`).
    public static func listen(path: String, backlog: Int32 = 64) throws(Error) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Error("socket") }

        do throws(Error) {
            try configure(fd)
            unlink(path)
            var address = try makeAddress(path)
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0 else { throw Error("bind") }
            guard chmod(path, 0o600) == 0 else { throw Error("chmod") }
            guard Darwin.listen(fd, backlog) == 0 else { throw Error("listen") }
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    /// Connects to a listening socket at `path`.
    public static func connect(path: String) throws(Error) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Error("socket") }

        do throws(Error) {
            try configure(fd)
            var address = try makeAddress(path)
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard connected == 0 else { throw Error("connect") }
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    /// The effective UID of the process on the other end of a connected socket.
    public static func peerUID(of fd: Int32) -> uid_t? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 ? uid : nil
    }

    /// The PID of the process on the other end of a connected socket.
    public static func peerPID(of fd: Int32) -> pid_t? {
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        return getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0 ? pid : nil
    }

    /// Writes the whole buffer, retrying on partial writes and `EINTR`.
    public static func writeAll(_ data: Data, to fd: Int32) throws(Error) {
        var failure: Error?
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard var pointer = buffer.baseAddress else { return }
            var remaining = buffer.count
            while remaining > 0 {
                let written = Darwin.write(fd, pointer, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    failure = Error("write")
                    return
                }
                pointer += written
                remaining -= written
            }
        }
        if let failure { throw failure }
    }

    /// Blocking read of a single newline-terminated line.
    ///
    /// Returns `nil` if the peer closed the connection before a full line, or
    /// if `shouldGiveUp` returns `true`; it is checked every
    /// `checkIntervalMilliseconds` while no data arrives.
    public static func readLine(
        from fd: Int32,
        maxBytes: Int = 4 << 20,
        checkIntervalMilliseconds: Int32 = 1000,
        shouldGiveUp: () -> Bool = { false }
    ) throws(Error) -> Data? {
        var line = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while line.count < maxBytes {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, checkIntervalMilliseconds)
            if ready < 0 {
                if errno == EINTR { continue }
                throw Error("poll")
            }
            if ready == 0 {
                if shouldGiveUp() { return nil }
                continue
            }
            let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                throw Error("read")
            }
            if count == 0 { return nil }
            if let newline = chunk[..<count].firstIndex(of: WireProtocol.delimiter) {
                line.append(contentsOf: chunk[..<newline])
                return line
            }
            line.append(contentsOf: chunk[..<count])
        }
        throw Error("read", code: EMSGSIZE)
    }

    public static func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }

    // MARK: - Private

    /// Close-on-exec, and no `SIGPIPE` when writing to a peer that went away:
    /// a closed peer must surface as an error, never kill the process.
    private static func configure(_ fd: Int32) throws(Error) {
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var on: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw Error("setsockopt")
        }
    }

    private static func makeAddress(_ path: String) throws(Error) -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { throw Error("socket path too long", code: ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }
}
