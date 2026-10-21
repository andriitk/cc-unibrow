import Foundation
import os
import UnibrowCore

/// Keeps `~/Library/Application Support/cc-unibrow/bin/unibrow-hook` pointing
/// at the relay binary that ships next to the app executable.
///
/// The Claude Code plugin only knows that stable path, so the app can live
/// anywhere (`/Applications`, `~/Applications`, a build folder) and moving it
/// is fixed by launching it once.
enum HookLinker {
    enum Status: Equatable {
        case linked(URL)
        case relayMissing
        case failed(String)
    }

    private static let logger = Logger(subsystem: "dev.andriitk.unibrow", category: "hook-link")

    static func link(fileManager: FileManager = .default) -> Status {
        guard let executable = Bundle.main.executableURL else { return .relayMissing }
        let relay = executable.deletingLastPathComponent().appending(path: "unibrow-hook")
        guard fileManager.isExecutableFile(atPath: relay.path(percentEncoded: false)) else {
            logger.error("Relay binary not found next to the app at \(relay.path, privacy: .public)")
            return .relayMissing
        }

        let link = Paths.hookLink()
        do {
            try fileManager.createDirectory(
                at: link.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            if let current = try? fileManager.destinationOfSymbolicLink(atPath: link.path(percentEncoded: false)),
               current == relay.path(percentEncoded: false) {
                return .linked(relay)
            }
            try? fileManager.removeItem(at: link)
            try fileManager.createSymbolicLink(at: link, withDestinationURL: relay)
            logger.info("Hook relay linked to \(relay.path, privacy: .public)")
            return .linked(relay)
        } catch {
            logger.error("Cannot link the hook relay: \(error.localizedDescription, privacy: .public)")
            return .failed(error.localizedDescription)
        }
    }
}
