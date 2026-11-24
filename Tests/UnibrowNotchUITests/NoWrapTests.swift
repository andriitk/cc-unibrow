import AppKit
import SwiftUI
import Testing
import UnibrowCore
@testable import UnibrowNotchUI

/// A narrow notch row once broke the app button into "Termin / al". Labels
/// and the session line must stay one line at any width.
@MainActor
@Suite("No wrapped labels")
struct NoWrapTests {
    private func size(_ view: some View, width: CGFloat) -> CGSize {
        NSHostingController(rootView: view).sizeThatFits(in: CGSize(width: width, height: 1_000))
    }

    @Test("A pill keeps its label on one line however little room it gets")
    func pill() {
        let button = Button(action: {}) {
            HStack(spacing: 3) {
                Text("Terminal")
                Image(systemName: "arrow.up.forward").imageScale(.small)
            }
        }
        .buttonStyle(.pill(.quiet))
        let natural = size(button, width: 1_000)
        for width in [10, 30, 50] as [CGFloat] {
            #expect(size(button, width: width).height == natural.height, "width \(width)")
        }
    }

    @Test("The session line stays one line and inside its width, from wide to very narrow")
    func sessionLine() {
        let row = SessionPlaceRow(
            projectName: "unibrow-pro", branch: "feat/island-wake-push", sessionTag: "704a",
            sessionID: "704a0000-0000", agents: nil, hostAppName: "Terminal", since: .now, onOpen: {})
        let oneLine = size(row, width: 2_000).height
        #expect(oneLine > 0)
        for width in stride(from: 520, through: 140, by: -10) as StrideThrough<CGFloat> {
            let measured = size(row, width: width)
            #expect(measured.height <= oneLine, "width \(width): wrapped")
            #expect(measured.width <= width, "width \(width): overflows")
        }
    }
}
