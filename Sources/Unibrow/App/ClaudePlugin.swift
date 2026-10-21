import Foundation
import os

/// Checks and installs the Claude Code plugin through the `claude` CLI, so a
/// user who installed only the app is one click away from a working setup.
///
/// The CLI is run through the user's login shell: a GUI app does not inherit
/// the PATH where `claude` lives (Homebrew, npm, ~/.local/bin…).
enum ClaudePlugin {
    enum Status: Equatable {
        case unknown
        case installed
        case notInstalled
        /// The `claude` command was not found.
        case claudeMissing
    }

    static let id = "cc-unibrow@cc-unibrow"
    static let repository = "andriitk/cc-unibrow"

    private static let logger = Logger(subsystem: "dev.andriitk.unibrow", category: "plugin")

    static func status() async -> Status {
        guard let result = await run("claude plugin list --json") else { return .unknown }
        if result.status == 127 { return .claudeMissing }
        guard result.status == 0 else { return .unknown }
        return isEnabled(inListJSON: result.output) ? .installed : .notInstalled
    }

    /// Installs (or re-enables) the plugin. Returns whether it is installed afterwards.
    static func install() async -> Bool {
        let command = """
        export CLAUDE_CODE_PLUGIN_PREFER_HTTPS=1
        claude plugin install cc-unibrow --marketplace \(repository) \
          || { claude plugin marketplace add \(repository); claude plugin install \(id); }
        """
        _ = await run(command)
        return await status() == .installed
    }

    /// `claude plugin list --json` prints an array of `{id, enabled, …}`.
    /// Login shells may print banners first, so start at the first `[`.
    static func isEnabled(inListJSON output: String) -> Bool {
        struct Entry: Decodable {
            let id: String
            let enabled: Bool?
        }
        guard let start = output.firstIndex(of: "["),
              let entries = try? JSONDecoder().decode([Entry].self, from: Data(output[start...].utf8))
        else { return false }
        return entries.contains { $0.id == id && $0.enabled != false }
    }

    // MARK: - Shell

    private struct Result {
        let status: Int32
        let output: String
    }

    /// Runs `command` in the user's login shell, off the main thread, with a timeout.
    private static func run(_ command: String, timeout: Duration = .seconds(60)) async -> Result? {
        await Task.detached(priority: .utility) { () -> Result? in
            let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
            let process = Process()
            process.executableURL = URL(filePath: shell)
            process.arguments = ["-l", "-c", command]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                logger.error("Cannot run the login shell: \(error.localizedDescription, privacy: .public)")
                return nil
            }

            let deadline = DispatchTime.now() + .seconds(Int(timeout.components.seconds))
            DispatchQueue.global().asyncAfter(deadline: deadline) {
                if process.isRunning { process.terminate() }
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return Result(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
        }.value
    }
}
