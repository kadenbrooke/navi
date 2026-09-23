import AppKit
import UserNotifications
import PetCore

/// Delivers the working → idle "waiting on you" signal as a macOS user notification, so it
/// survives you looking away (the pop + chime last two seconds; Notification Center
/// keeps the line). UNUserNotificationCenter needs a real bundle — from `swift run` there is
/// none and the framework traps — so an unbundled build falls back to `osascript`.
final class IdleNotifier {
    private let bundled = Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    private var authorization = IdleNotificationAuthorization()
    private var cooldown = IdleAlertCooldown(interval: 60)

    func prepare() {
        guard bundled else { return }
        perform(authorization.prepare())
    }

    func post(_ alert: IdleAlert) {
        guard cooldown.shouldPost(threadID: alert.id, now: Date().timeIntervalSince1970) else { return }
        NSLog("Navi: idle alert — %@", alert.message)
        if bundled {
            perform(authorization.post(alert))
        } else {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = [
                "-e", "on run argv",
                "-e", "display notification (item 1 of argv) with title \"Navi\"",
                "-e", "end run",
                alert.message,
            ]
            try? p.run()
        }
    }

    private func perform(_ actions: [IdleNotificationAuthorization.Action]) {
        for action in actions {
            switch action {
            case .checkSettings:
                UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
                    guard let self else { return }
                    let status: IdleNotificationAuthorization.Settings
                    switch settings.authorizationStatus {
                    case .notDetermined: status = .notDetermined
                    case .authorized, .provisional, .ephemeral: status = .authorized
                    case .denied: status = .denied
                    @unknown default: status = .denied
                    }
                    DispatchQueue.main.async {
                        self.perform(self.authorization.resolveSettings(status))
                    }
                }
            case .requestAuthorization:
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] ok, err in
                    guard let self else { return }
                    if let err { NSLog("Navi: notification authorization failed: %@", String(describing: err)) }
                    DispatchQueue.main.async {
                        self.perform(self.authorization.resolve(authorized: ok))
                    }
                }
            case .drop:
                NSLog("Navi: idle alert dropped — notification permission denied")
            case .deliver(let alert):
                let content = UNMutableNotificationContent()
                content.title = "Navi"
                content.body = alert.message
                content.sound = nil // Navi already chimes; one sound is enough
                let req = UNNotificationRequest(identifier: "idle:\(alert.id)", content: content, trigger: nil)
                UNUserNotificationCenter.current().add(req) { err in
                    if let err { NSLog("Navi: notification add failed: %@", String(describing: err)) }
                }
            }
        }
    }
}
