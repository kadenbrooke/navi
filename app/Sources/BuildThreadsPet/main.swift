import AppKit

// One Navi at a time: the LaunchAgent (install.sh) and a stray `open`/Launch-at-Login can
// both start her. A second instance exits cleanly (0) so launchd's KeepAlive, which only
// relaunches on a non-zero exit, leaves it alone.
if let me = Bundle.main.bundleIdentifier {
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: me)
        .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    if !others.isEmpty {
        NSLog("Navi: already running (pid %d) — this instance exits", others[0].processIdentifier)
        exit(0)
    }
}

// Accessory policy: no Dock icon, never becomes the frontmost app on launch.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
