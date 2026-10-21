public import Foundation

/// Picks the window that belongs to a project from a list of window titles.
///
/// Ranking: the full path in the title (terminals) beats the project name as
/// a whole title segment (`main.py — shop-api`, IDEs) beats the name anywhere
/// in the title. So `api` does not grab a `shop-api` window when a window for
/// `api` exists.
public enum WindowTitleMatcher {
    public static func bestMatch(titles: [String], projectPath: String, home: String = NSHomeDirectory()) -> Int? {
        let name = URL(filePath: projectPath).lastPathComponent
        guard !name.isEmpty, name != "/" else { return nil }
        let tildePath = !home.isEmpty && projectPath.hasPrefix(home)
            ? "~" + projectPath.dropFirst(home.count)
            : projectPath

        func score(_ title: String) -> Int {
            if title.contains(projectPath) || title.contains(tildePath) { return 3 }
            if segments(of: title).contains(name) { return 2 }
            if title.localizedCaseInsensitiveContains(name) { return 1 }
            return 0
        }

        let scored = titles.enumerated().map { (index: $0.offset, score: score($0.element)) }
        guard let best = scored.max(by: { $0.score < $1.score }), best.score > 0 else { return nil }
        return best.index
    }

    /// `main.py — shop-api — Cursor` → `["main.py", "shop-api", "Cursor"]`.
    /// Only spaced separators split: a bare "-" is part of names like `web-api`.
    static func segments(of title: String) -> [String] {
        var normalized = title
        for separator in [" — ", " – ", " - ", " | ", " · "] {
            normalized = normalized.replacingOccurrences(of: separator, with: "\u{0}")
        }
        return normalized
            .split(separator: "\u{0}")
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
