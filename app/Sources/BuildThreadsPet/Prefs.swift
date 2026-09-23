import AppKit
import PetCore

/// UserDefaults-backed settings. Keys are stable so the .app bundle and `swift run`
/// share them when the bundle id matches.
enum Prefs {
    private static let d = UserDefaults.standard

    /// The whole Navi config as one JSON blob in the mock's Share-box shape
    /// (`{ preset, mode, menuSort, params }`). Paste the playground's JSON here via the
    /// menubar → "Paste Navi config from clipboard".
    static var config: NaviConfig {
        get {
            guard let s = d.string(forKey: "naviConfig"), let c = try? NaviConfig.decode(Data(s.utf8)) else { return NaviConfig() }
            return c
        }
        set {
            if let data = try? newValue.encode() { d.set(String(decoding: data, as: UTF8.self), forKey: "naviConfig") }
        }
    }

    /// Click / Enter on an Omnigent-backed row opens the chat in the desktop app
    /// (`omnigent://`) by default; this flips it to the web UI (`http://127.0.0.1:6767/c/…`).
    static let openChatsInBrowserKey = "openChatsInBrowser"
    static var openChatsInBrowser: Bool {
        get { d.bool(forKey: openChatsInBrowserKey) }
        set { d.set(newValue, forKey: openChatsInBrowserKey) }
    }

    /// macOS user notification when a thread's parent agent goes working → idle ("<name> is
    /// waiting on you"). Default ON; stored inverted so an unset key reads as on.
    static let idleNotificationsOffKey = "idleNotificationsOff"
    static var idleNotifications: Bool {
        get { !d.bool(forKey: idleNotificationsOffKey) }
        set { d.set(!newValue, forKey: idleNotificationsOffKey) }
    }

    /// Manual nap survives a relaunch.
    static var sleeping: Bool {
        get { d.bool(forKey: "sleeping") }
        set { d.set(newValue, forKey: "sleeping") }
    }

    /// Hidden (menubar Triforce / ⌥⌘N) survives a relaunch. Key owned by `NaviVisibility`.
    static var visibility: NaviVisibility {
        get { NaviVisibility(store: d) }
        set { newValue.save(to: d) }
    }

    /// Where she rests when not following the cursor (scene coords, y down).
    static var home: NSPoint? {
        get {
            guard d.object(forKey: "homeX") != nil, d.object(forKey: "homeY") != nil else { return nil }
            return NSPoint(x: d.double(forKey: "homeX"), y: d.double(forKey: "homeY"))
        }
        set {
            guard let p = newValue else { d.removeObject(forKey: "homeX"); d.removeObject(forKey: "homeY"); return }
            d.set(Double(p.x), forKey: "homeX"); d.set(Double(p.y), forKey: "homeY")
        }
    }

    /// thread id → seconds since 1970 of the last Navi-state change seen. Drives the menu's
    /// "recent" sort across relaunches (the collector does not emit change times).
    static var changedAt: [String: Double] {
        get { d.dictionary(forKey: "changedAt") as? [String: Double] ?? [:] }
        set { d.set(newValue, forKey: "changedAt") }
    }
}

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    private static func envPath(_ key: String) -> URL? {
        guard let v = ProcessInfo.processInfo.environment[key], !v.isEmpty else { return nil }
        return URL(fileURLWithPath: (v as NSString).expandingTildeInPath)
    }
    /// The collector's snapshot. `NAVI_THREADS_PATH` overrides it — install.sh bakes the same
    /// value into both launchd agents so the collector and the app always agree.
    static let threadsJSON: URL = envPath("NAVI_THREADS_PATH")
        ?? home.appendingPathComponent(".navi/threads.json")
    /// Your own sound files (see README → Sounds). None ship with Navi; missing = silent.
    static let sfxDir: URL = envPath("NAVI_SFX_DIR")
        ?? home.appendingPathComponent("Library/Application Support/Navi/sfx", isDirectory: true)
    static let collectorInstallHint = "collector not running — run ./install.sh"
}
