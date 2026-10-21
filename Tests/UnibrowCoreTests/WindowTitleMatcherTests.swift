import Testing
@testable import UnibrowCore

@Suite("Window title matching")
struct WindowTitleMatcherTests {
    private let home = "/Users/me"

    @Test("Picks the Cursor window of the right project among many")
    func cursorWindows() {
        let titles = [
            "README.md — web-api",
            "main.py — billing-service",
            "notes-app",
        ]
        #expect(WindowTitleMatcher.bestMatch(
            titles: titles, projectPath: "/Users/me/Dev/acme/billing-service", home: home
        ) == 1)
    }

    @Test("Hyphenated names are not split apart")
    func hyphenatedName() {
        #expect(WindowTitleMatcher.segments(of: "app.py — web-api — Cursor") == ["app.py", "web-api", "Cursor"])
    }

    @Test("A whole segment beats a substring: `api` prefers its own window over `shop-api`")
    func exactSegmentWins() {
        let titles = ["index.ts — shop-api", "server.ts — api"]
        #expect(WindowTitleMatcher.bestMatch(titles: titles, projectPath: "/Users/me/code/api", home: home) == 1)
    }

    @Test("A terminal title with the full path wins", arguments: [
        "me@mac: /Users/me/code/shop",
        "zsh — ~/code/shop",
    ])
    func terminalPath(title: String) {
        let titles = ["shop notes", title]
        #expect(WindowTitleMatcher.bestMatch(titles: titles, projectPath: "/Users/me/code/shop", home: home) == 1)
    }

    @Test("No match returns nil so the caller can fall back")
    func noMatch() {
        #expect(WindowTitleMatcher.bestMatch(titles: ["Mail", "Notes"], projectPath: "/p/shop", home: home) == nil)
        #expect(WindowTitleMatcher.bestMatch(titles: ["shop"], projectPath: "", home: home) == nil)
    }
}
