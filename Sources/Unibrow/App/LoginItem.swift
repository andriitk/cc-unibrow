import os
import ServiceManagement

/// "Launch at Login" via the system login items (macOS 13+).
/// Only works when running from an `.app` bundle.
enum LoginItem {
    private static let logger = Logger(subsystem: "dev.andriitk.unibrow", category: "login-item")

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            logger.error("Cannot update the login item: \(error.localizedDescription, privacy: .public)")
        }
    }
}
