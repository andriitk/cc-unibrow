public import Darwin
import Foundation

/// The ancestors of a process, nearest first: hook → sh → claude → shell →
/// terminal or IDE. Used to find the app a Claude Code session runs in.
///
/// tmux needs one extra step: its server is detached from the terminal (its
/// parent is launchd), so when the walk reaches a tmux server it continues
/// from the tmux clients attached to it, which do run inside a terminal app.
///
/// The hook relay runs this for itself and sends the result: asynchronous
/// hooks exit right after sending, so the app could not walk their tree later.
public enum ProcessAncestry {
    /// Deep enough for IDE helpers (e.g. IDE → helper → shell → claude → sh → hook).
    private static let maxDepth = 24

    /// Every ancestor PID of `pid`, nearest first, following tmux into its
    /// attached clients. Pure process inspection; safe off the main thread.
    public static func candidates(of pid: pid_t) -> [pid_t] {
        var result: [pid_t] = []
        var queue: [pid_t] = [pid]
        var seen: Set<pid_t> = []

        while let start = queue.first, result.count < maxDepth * 4 {
            queue.removeFirst()
            var current = start
            for _ in 0..<maxDepth {
                guard current > 1, seen.insert(current).inserted else { break }
                result.append(current)
                if processName(of: current) == "tmux" {
                    queue.append(contentsOf: tmuxClientPIDs(server: current))
                }
                guard let parent = parentPID(of: current) else { break }
                current = parent
            }
        }
        return result
    }

    // MARK: - Process inspection

    /// Uses `sysctl(KERN_PROC_PID)`, like `ps`, rather than `proc_pidinfo`:
    /// the latter refuses processes owned by root, and Terminal.app starts
    /// every shell through the root-owned `login`, which would end the walk
    /// one step before the terminal.
    static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    private static func processName(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXCOMLEN) * 2 + 1)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return string(fromNullTerminated: buffer)
    }

    private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return string(fromNullTerminated: buffer)
    }

    private static func string(fromNullTerminated buffer: [CChar]) -> String {
        String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// PIDs of the clients attached to a tmux server, most recently active first.
    private static func tmuxClientPIDs(server: pid_t) -> [pid_t] {
        // Ask the same tmux binary the server runs, so Homebrew, MacPorts and
        // custom builds all work.
        guard let tmux = executablePath(of: server) else { return [] }
        let process = Process()
        process.executableURL = URL(filePath: tmux)
        process.arguments = ["list-clients", "-F", "#{client_activity} #{client_pid}"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return []
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [] }

        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .compactMap { line -> (activity: Int, pid: pid_t)? in
                let fields = line.split(separator: " ")
                guard fields.count == 2, let activity = Int(fields[0]), let pid = pid_t(fields[1]) else { return nil }
                return (activity, pid)
            }
            .sorted { $0.activity > $1.activity }
            .map(\.pid)
    }
}
