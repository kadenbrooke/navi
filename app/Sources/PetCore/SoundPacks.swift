import Foundation

/// A typing-sound profile: a folder of samples fetched by `keysounds/fetch-keysounds.sh`
/// (never committed), or the built-in synth click.
///
/// Folder layout, written by the fetch script:
/// ```
/// <keysounds dir>/<id>/pack.json        {"id","name","license","tier","source","attribution"}
/// <keysounds dir>/<id>/key-01.wav …     ordinary keys (required; a pack without them is skipped)
/// <keysounds dir>/<id>/space-01.wav …   optional; missing classes use the key samples
/// <keysounds dir>/<id>/enter-01.wav …
/// <keysounds dir>/<id>/backspace-01.wav …
/// ```
public struct SoundPack: Equatable, Sendable {
    public enum Tier: String, Sendable, Comparable {
        /// Redistributable (CC0 / CC-BY), listed in `keysounds/packs-public.tsv`.
        case `public`
        /// A pack you added yourself (your own folder, or `keysounds/packs-local.tsv`).
        /// Its license is yours to check; Navi never redistributes it.
        case local
        case builtin

        private var order: Int { self == .public ? 0 : (self == .local ? 1 : 2) }
        public static func < (a: Tier, b: Tier) -> Bool { a.order < b.order }
    }

    public var id: String
    public var name: String
    public var license: String
    public var tier: Tier
    public var attribution: String?
    public var samples: [KeyClass: [URL]]

    public init(id: String, name: String, license: String, tier: Tier, attribution: String? = nil, samples: [KeyClass: [URL]] = [:]) {
        self.id = id; self.name = name; self.license = license; self.tier = tier; self.attribution = attribution; self.samples = samples
    }

    /// The class's own samples, else the ordinary-key ones.
    public func samples(for c: KeyClass) -> [URL] {
        if let s = samples[c], !s.isEmpty { return s }
        return samples[.other] ?? []
    }

    public static let synth = SoundPack(id: "synth", name: "Synth click", license: "built-in", tier: .builtin)

    /// Dropdown label: `Cherry KC 1000 · CC0`, `My Pack · local`, `Synth click · built-in`.
    public var menuTitle: String {
        switch tier {
        case .public: return "\(name) · \(license)"
        case .local: return "\(name) · local"
        case .builtin: return "\(name) · built-in"
        }
    }

    /// Hover text: license, attribution, where it came from.
    public var tooltip: String {
        var parts = ["License: \(license)"]
        if let attribution, !attribution.isEmpty { parts.append(attribution) }
        if tier == .local { parts.append("Your own pack: added on this Mac, never redistributed by Navi.") }
        return parts.joined(separator: "\n")
    }
}

public enum SoundPackLibrary {
    /// Audio CoreAudio decodes. Anything else in a pack folder is ignored.
    public static let audioExtensions: Set<String> = ["wav", "mp3", "flac", "aif", "aiff", "caf", "m4a"]
    /// Variants loaded per class, so a huge pack cannot balloon memory.
    public static let maxVariants = 32

    private struct Meta: Decodable {
        var name: String?
        var license: String?
        var tier: String?
        var attribution: String?
    }

    /// Every valid pack under `dir` (public first, then local, by name), then the synth click.
    /// A missing folder, a folder with no key samples, or a broken pack.json never throws:
    /// the pack is skipped or named after its folder.
    public static func scan(_ dir: URL, fileManager fm: FileManager = .default) -> [SoundPack] {
        let folders = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        var packs: [SoundPack] = []
        for folder in folders where (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            if folder.lastPathComponent.hasSuffix(".part") { continue }   // a fetch in progress
            let files = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
                .filter { audioExtensions.contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            var samples: [KeyClass: [URL]] = [:]
            for c in KeyClass.allCases {
                let mine = files.filter { $0.deletingPathExtension().lastPathComponent.hasPrefix(c.filePrefix + "-") }
                if !mine.isEmpty { samples[c] = Array(mine.prefix(maxVariants)) }
            }
            guard samples[.other] != nil else { continue }
            let meta = (try? Data(contentsOf: folder.appendingPathComponent("pack.json"))).flatMap { try? JSONDecoder().decode(Meta.self, from: $0) }
            let id = folder.lastPathComponent
            packs.append(SoundPack(id: id, name: meta?.name ?? id, license: meta?.license ?? "unknown",
                                   tier: meta?.tier.flatMap { SoundPack.Tier(rawValue: $0) }.flatMap { $0 == .builtin ? nil : $0 } ?? .local,
                                   attribution: meta?.attribution, samples: samples))
        }
        packs.sort { ($0.tier, $0.name.lowercased()) < ($1.tier, $1.name.lowercased()) }
        return packs + [SoundPack.synth]
    }

    /// The chosen pack, or — when it is gone — the first fetched pack, or the synth click.
    public static func resolve(_ id: String?, in packs: [SoundPack]) -> SoundPack {
        if let id, let p = packs.first(where: { $0.id == id }) { return p }
        return packs.first { $0.tier != .builtin } ?? .synth
    }
}

/// The dropdown's typing items, as text. The AppKit side only draws them.
public enum TypingMenu {
    public static let toggleTitle = "Typing sounds"
    public static let profileTitle = "Typing sound"
    public static let openSettings = "Open Input Monitoring settings…"
    public static let openPacksFolder = "Open typing sounds folder"
    public static let toggleTooltip = "Plays a click for every key press, anywhere, and shows your typing speed. Which keys you press is never stored."

    /// Where a typing listener stands.
    public enum Listener: Equatable, Sendable { case off, needsPermission, running }

    /// `⌨ 72 wpm · today best 95 · avg 61`; `⌨ 0 wpm · nothing typed today` before the first press.
    public static func wpmLine(live: Int, today: TypingStats) -> String {
        if today.keystrokes == 0 { return "⌨ \(live) wpm · nothing typed today" }
        var parts = ["⌨ \(live) wpm"]
        if today.bestWPM > 0 { parts.append("today best \(today.bestWPM)") }
        if let avg = today.averageWPM { parts.append("avg \(avg)") }
        if parts.count == 1 { parts.append("\(today.keystrokes) keys today") }
        return parts.joined(separator: " · ")
    }

    /// What goes under the toggle, top to bottom.
    public enum Row: Equatable, Sendable {
        /// The WPM / today line (`wpmLine`).
        case stats
        case note(String)
        /// *Open Input Monitoring settings…*
        case openSettings
    }

    /// Under the toggle when the feature is on: today's stats always (they are saved, so they
    /// read even while permission is missing), then the status note, then the settings link
    /// when permission is missing. Nothing when off.
    public static func rows(enabled: Bool, listener: Listener, secureInput: Bool, muteReason: String?) -> [Row] {
        guard enabled else { return [] }
        var rows: [Row] = [.stats]
        if let n = statusNote(enabled: enabled, listener: listener, secureInput: secureInput, muteReason: muteReason) { rows.append(.note(n)) }
        if listener == .needsPermission { rows.append(.openSettings) }
        return rows
    }

    /// One dim line under the toggle, or nil when all is well.
    public static func statusNote(enabled: Bool, listener: Listener, secureInput: Bool, muteReason: String?) -> String? {
        guard enabled else { return nil }
        if listener == .needsPermission { return "needs Input Monitoring permission" }
        if secureInput { return "paused · a password field has secure input on" }
        return muteReason
    }

    /// `Typing sound · Cherry KC 1000`.
    public static func profileMenuTitle(_ pack: SoundPack) -> String { "\(profileTitle) · \(pack.name)" }

    /// Shown when no pack is fetched (only the synth click is available).
    public static func missingPacksNote(_ packs: [SoundPack]) -> String? {
        packs.contains { $0.tier != .builtin } ? nil : "no sound packs fetched → synth click (run keysounds/fetch-keysounds.sh)"
    }

    public static func volumeTitle(_ v: Double) -> String { "Volume \(Int((KeySoundSettings.clamp(v) * 100).rounded()))%" }
}
