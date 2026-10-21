public import Foundation

/// Reads the current git branch of a directory straight from `.git/HEAD`,
/// without spawning `git`. Handles worktrees, where `.git` is a file that
/// points at the real git directory.
public enum GitBranch {
    public struct Repository: Sendable, Equatable {
        /// The working-tree root: the folder that contains `.git`.
        public let root: String
        /// Current branch, or a short hash for a detached HEAD.
        public let branch: String?
    }

    public static func current(in directory: String, fileManager: FileManager = .default) -> String? {
        repository(containing: directory, fileManager: fileManager)?.branch
    }

    /// The repository that contains `directory`, found by walking up to the
    /// folder with `.git`; `nil` outside a repository.
    public static func repository(containing directory: String, fileManager: FileManager = .default) -> Repository? {
        guard !directory.isEmpty else { return nil }
        var url = URL(filePath: directory, directoryHint: .isDirectory)

        // Walk up to the repository root; stop at the file-system root.
        while true {
            let dotGit = url.appending(path: ".git")
            if let head = headContents(dotGit: dotGit, fileManager: fileManager) {
                return Repository(root: url.path(percentEncoded: false).trimmingTrailingSlash, branch: parse(head: head))
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { return nil }
            url = parent
        }
    }

    /// `ref: refs/heads/main` → `main`; a detached HEAD → its short hash.
    static func parse(head: String) -> String? {
        let line = head.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix("ref: ") {
            let ref = line.dropFirst("ref: ".count)
            return ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : String(ref)
        }
        return line.isEmpty ? nil : String(line.prefix(7))
    }

    private static func headContents(dotGit: URL, fileManager: FileManager) -> String? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) else { return nil }

        if isDirectory.boolValue {
            return try? String(contentsOf: dotGit.appending(path: "HEAD"), encoding: .utf8)
        }
        // Worktree: `.git` contains `gitdir: <path>`.
        guard let pointer = try? String(contentsOf: dotGit, encoding: .utf8),
              pointer.hasPrefix("gitdir: ")
        else { return nil }
        let path = pointer.dropFirst("gitdir: ".count).trimmingCharacters(in: .whitespacesAndNewlines)
        let gitDir = path.hasPrefix("/")
            ? URL(filePath: path)
            : dotGit.deletingLastPathComponent().appending(path: path)
        return try? String(contentsOf: gitDir.appending(path: "HEAD"), encoding: .utf8)
    }
}

private extension String {
    var trimmingTrailingSlash: String {
        count > 1 && hasSuffix("/") ? String(dropLast()) : self
    }
}
