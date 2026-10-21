import AppKit
import SwiftUI

@main
struct UnibrowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: delegate.model)
        } label: {
            MenuBarLabel(model: delegate.model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var notch: NotchPanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A menu-bar utility: no Dock icon, no app switcher entry.
        NSApp.setActivationPolicy(.accessory)
        model.start()

        let notch = NotchPanelController(model: model)
        notch.show()
        self.notch = notch
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
    }
}
