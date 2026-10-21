public import Foundation

/// File-system locations shared by the app and the hook relay.
///
/// Everything lives in a per-user directory with `0700` permissions instead of
/// a world-readable `/tmp` path.
public enum Paths {
    public static let appSupportName = "cc-unibrow"

    /// Overrides the socket path. Useful for tests and for running a second,
    /// development copy of the app next to the installed one.
    public static let socketPathEnvironmentKey = "UNIBROW_SOCKET"

    public static func supportDirectory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home
            .appending(path: "Library/Application Support", directoryHint: .isDirectory)
            .appending(path: appSupportName, directoryHint: .isDirectory)
    }

    public static func socketPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let override = environment[socketPathEnvironmentKey], !override.isEmpty {
            return override
        }
        return supportDirectory().appending(path: "unibrow.sock").path(percentEncoded: false)
    }

    /// Stable path to the hook relay. The app points this symlink at the binary
    /// inside its bundle on every launch, so the Claude Code plugin never needs
    /// to know where the app is installed.
    public static func hookLink() -> URL {
        supportDirectory().appending(path: "bin/unibrow-hook")
    }
}
