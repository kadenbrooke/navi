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

    func prepare() {
        guard bundled else { return }
        perform(authorization.prepare())
    }

    func post(_ alert: IdleAlert) {
        NSLog("Navi: idle alert — %@", alert.message)
        if bundled {
            perform(authorization.post(alert))
        } else {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            let body = alert.message.replacingOccurrences(of: "\"", with: "\\\"")
            p.arguments = ["-e", "display notification \"\(body)\" with title \"Navi\""]
            try? p.run()
        }
    }

    private func perform(_ actions: [IdleNotificationAuthorization.Action]) {
        for action in actions {
            switch action {
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
