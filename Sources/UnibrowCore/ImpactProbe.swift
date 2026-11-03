public import Foundation
import Darwin

/// The read-only lookups an impact note needs, injectable so tests can
/// replace them. `live` runs `git` and reads the file system; every call
/// takes a deadline and gives up (returns `nil`, or stops counting) when it
/// passes.
public struct ImpactProbe: Sendable {
    public enum Entry: Sendable, Equatable {
        case file, directory, symlink, other
    }

    /// Standard output of a successful `git` run in a directory, or `nil`.
    public var git: @Sendable (_ arguments: [String], _ directory: String, _ deadline: ContinuousClock.Instant) -> Data?
    /// What is at a path, without following a symlink there; `nil` if nothing.
    public var entry: @Sendable (_ path: String) -> Entry?
    /// Items (files, folders, links) inside a folder, never following
    /// symlinks. Stops at `cap` or at the deadline; `complete` says whether
    /// it counted everything.
    public var countItems: @Sendable (_ directory: String, _ cap: Int, _ deadline: ContinuousClock.Instant) -> (count: Int, complete: Bool)
    /// The real path of an existing folder (symlinks and `..` resolved).
    public var realPath: @Sendable (_ path: String) -> String?

    public init(
        git: @escaping @Sendable (_ arguments: [String], _ directory: String, _ deadline: ContinuousClock.Instant) -> Data?,
        entry: @escaping @Sendable (_ path: String) -> Entry?,
        countItems: @escaping @Sendable (_ directory: String, _ cap: Int, _ deadline: ContinuousClock.Instant) -> (count: Int, complete: Bool),
        realPath: @escaping @Sendable (_ path: String) -> String?
    ) {
        self.git = git
        self.entry = entry
        self.countItems = countItems
        self.realPath = realPath
    }

    /// The real lookups. `environment` is the relay's own (the session's),
    /// so `git` is the one the command itself would run.
    public static func live(environment: [String: String] = ProcessInfo.processInfo.environment) -> ImpactProbe {
        let gitPath = executable(named: "git", path: environment["PATH"])
        var gitEnvironment = environment
        // Never take the index lock or refresh the index: a probe must not
        // write to the repository or block a git the user runs.
        gitEnvironment["GIT_OPTIONAL_LOCKS"] = "0"
        gitEnvironment["GIT_TERMINAL_PROMPT"] = "0"
        // No on-demand fetch of missing objects in a partial clone (git
        // 2.44+; older gits are covered by the partial-clone check).
        gitEnvironment["GIT_NO_LAZY_FETCH"] = "1"
        gitEnvironment["LC_ALL"] = "C"
        let fixedEnvironment = gitEnvironment
        return ImpactProbe(
            git: { arguments, directory, deadline in
                guard let gitPath else { return nil }
                // No fsmonitor program, no hooks and no transport (so no
                // network, ssh command or remote helper), whatever the
                // repository's config names. Filters are switched off by
                // the caller (`CommandImpact`) for `git status`.
                return run(
                    gitPath,
                    ["-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-c", "protocol.allow=never", "--no-pager"]
                        + arguments,
                    in: directory,
                    environment: fixedEnvironment,
                    deadline: deadline
                )
            },
            entry: entry(at:),
            countItems: countItems(in:cap:deadline:),
            realPath: { path in
                guard let resolved = Darwin.realpath(path, nil) else { return nil }
                defer { free(resolved) }
                return String(cString: resolved)
            }
        )
    }

    /// Largest output read from one `git` run; more counts as a failure.
    static let maxOutput = 4 << 20

    static func executable(named name: String, path: String?) -> URL? {
        for directory in (path ?? "/usr/bin:/bin").split(separator: ":") where directory.hasPrefix("/") {
            let candidate = String(directory) + "/" + name
            if access(candidate, X_OK) == 0 { return URL(filePath: candidate) }
        }
        return nil
    }

    /// Runs a program and returns its standard output, or `nil` if it fails,
    /// writes more than `maxOutput`, or is still running at the deadline (it
    /// is then terminated).
    static func run(
        _ executable: URL,
        _ arguments: [String],
        in directory: String,
        environment: [String: String],
        deadline: ContinuousClock.Instant
    ) -> Data? {
        guard deadline > .now else { return nil }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = URL(filePath: directory, directoryHint: .isDirectory)
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let output = OutputBuffer(limit: maxOutput)
        let finished = DispatchSemaphore(value: 0)
        let reader = pipe.fileHandleForReading
        do {
            try process.run()
        } catch {
            return nil
        }
        // Read on another thread so a full pipe never blocks the program.
        DispatchQueue.global(qos: .userInitiated).async {
            while true {
                let chunk = reader.availableData
                if chunk.isEmpty { break }
                output.append(chunk)
            }
            finished.signal()
        }
        guard finished.wait(timeout: dispatchTime(for: deadline)) == .success else {
            process.terminate()
            return nil
        }
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { return nil }
        return output.data
    }

    static func dispatchTime(for deadline: ContinuousClock.Instant) -> DispatchTime {
        // In seconds as a Double: no integer overflow for a far deadline,
        // and no 2-second cap (Int32 nanoseconds) on a long one.
        let seconds = ContinuousClock.now.duration(to: deadline) / .seconds(1)
        return .now() + min(max(0, seconds), 3_600)
    }

    static func entry(at path: String) -> Entry? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        switch info.st_mode & S_IFMT {
        case S_IFDIR: return .directory
        case S_IFLNK: return .symlink
        case S_IFREG: return .file
        default: return .other
        }
    }

    /// Walks a folder with `readdir`, depth first, without following
    /// symlinks (a link is counted, not entered) and without crossing into
    /// folders it cannot open.
    static func countItems(in directory: String, cap: Int, deadline: ContinuousClock.Instant) -> (count: Int, complete: Bool) {
        var pending = [directory]
        var count = 0
        while let folder = pending.popLast() {
            // O_NOFOLLOW: a folder swapped for a symlink since it was listed,
            // or a symlink given as the start, is not entered.
            let descriptor = open(folder, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { continue }
            guard let handle = fdopendir(descriptor) else {
                close(descriptor)
                continue
            }
            defer { closedir(handle) }
            while let item = readdir(handle) {
                let name = withUnsafeBytes(of: item.pointee.d_name) { buffer in
                    String(decoding: buffer.prefix(Int(item.pointee.d_namlen)), as: UTF8.self)
                }
                if name == "." || name == ".." { continue }
                count += 1
                if count >= cap { return (count, false) }
                if count % 64 == 0, ContinuousClock.now >= deadline { return (count, false) }
                let child = folder.hasSuffix("/") ? folder + name : folder + "/" + name
                switch Int32(item.pointee.d_type) {
                case DT_DIR: pending.append(child)
                case DT_UNKNOWN: if entry(at: child) == .directory { pending.append(child) }
                default: break
                }
            }
        }
        return (count, true)
    }
}

/// Collects a child's output from the reading thread.
private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var overflowed = false
    private let limit: Int

    init(limit: Int) { self.limit = limit }

    func append(_ chunk: Data) {
        lock.withLock {
            guard !overflowed else { return }
            if buffer.count + chunk.count > limit {
                overflowed = true
                buffer = Data()
            } else {
                buffer.append(chunk)
            }
        }
    }

    var data: Data? {
        lock.withLock { overflowed ? nil : buffer }
    }
}
