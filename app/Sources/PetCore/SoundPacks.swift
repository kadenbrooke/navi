import Foundation

/// A typing-sound profile: a folder of samples fetched by `keysounds/fetch-keysounds.sh`
/// (never committed), or the built-in synth click.
///
/// Folder layout, written by the fetch script:
/// ```
/// <keysounds dir>/<id>/pack.json        {"id","name","license","tier","source","attribution"}
/// <keysounds dir>/<id>/key-01.wav …     generic key presses
/// <keysounds dir>/<id>/sc30.wav …       one key's own press, by Mechvibes scancode (30 = A)
/// <keysounds dir>/<id>/row0-01.mp3 …    presses per keyboard row 0…4
/// <keysounds dir>/<id>/space-01.wav …   optional; space / enter / backspace keep their own
/// <keysounds dir>/<id>/enter-01.wav …
/// <keysounds dir>/<id>/backspace-01.wav …
/// <keysounds dir>/<id>/up-key-01.mp3 …  optional key-up recordings (also up-space- / up-enter- /
///                                       up-backspace-); without them releases are derived
/// ```
/// A pack needs at least one press (`key-`, `sc` or `row` files); otherwise it is skipped.
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
    /// Presses by class: `.other` = `key-NN`, plus `space-` / `enter-` / `backspace-NN`.
    public var samples: [KeyClass: [URL]]
    /// `row<r>-NN`, row → presses.
    public var rows: [Int: [URL]]
    /// `sc<scancode>`, one press per key.
    public var perKey: [Int: URL]
    /// `up-key-NN` (`.other`) and `up-space-` / `up-enter-` / `up-backspace-NN`.
    public var releases: [KeyClass: [URL]]

    /// The pack's folder (nil for the synth click).
    public var folder: URL?

    public init(id: String, name: String, license: String, tier: Tier, attribution: String? = nil, samples: [KeyClass: [URL]] = [:],
                rows: [Int: [URL]] = [:], perKey: [Int: URL] = [:], releases: [KeyClass: [URL]] = [:], folder: URL? = nil) {
        self.id = id; self.name = name; self.license = license; self.tier = tier; self.attribution = attribution; self.samples = samples
        self.rows = rows; self.perKey = perKey; self.releases = releases; self.folder = folder
    }

    /// Every file the pack plays from.
    public var files: [URL] {
        samples.values.flatMap { $0 } + rows.values.flatMap { $0 } + Array(perKey.values) + releases.values.flatMap { $0 }
    }

    /// The class's own samples, else the ordinary-key ones.
    public func samples(for c: KeyClass) -> [URL] {
        if let s = samples[c], !s.isEmpty { return s }
        return samples[.other] ?? []
    }

    /// At least one press any key can play.
    public var hasPresses: Bool { !(samples[.other] ?? []).isEmpty || !rows.isEmpty || !perKey.isEmpty }

    public static let synth = SoundPack(id: "synth", name: "Synth click", license: "built-in", tier: .builtin)

    /// What decoding this pack found, once it has been loaded: whether its per-key and class
    /// recordings that actually decode still record every key (`MacKeyboard.recordsEveryKey`).
    /// nil = not loaded yet; the star then goes by its files alone.
    public var decodedEveryKey: Bool? = nil

    /// The ★: its own real recording for every key of a standard Mac keyboard, fn excluded
    /// (`MacKeyboard.starKeyCodes`). Worked out from the files the pack actually has, so a new pack
    /// earns its star by itself, and taken away once a load shows some of them do not decode.
    public var hasEveryKey: Bool {
        let classes = Set(KeyClass.allCases.filter { $0 != .other && !(samples[$0] ?? []).isEmpty })
        return decodedEveryKey != false && MacKeyboard.recordsEveryKey(perKey: Set(perKey.keys), classes: classes)
    }

    /// Follows the name of a pack that `hasEveryKey`.
    public static let everyKeyMark = "★"

    /// Dropdown label: `Cherry KC 1000 · CC0`, `My Pack · local`, `Synth click · built-in`,
    /// `My Pack ★ · local` for a pack with every key recorded.
    public var menuTitle: String {
        let label = hasEveryKey ? "\(name) \(SoundPack.everyKeyMark)" : name
        switch tier {
        case .public: return "\(label) · \(license)"
        case .local: return "\(label) · local"
        case .builtin: return "\(label) · built-in"
        }
    }

    /// Hover text: license, attribution, where it came from.
    public var tooltip: String {
        var parts = hasEveryKey ? ["\(SoundPack.everyKeyMark) Every key of a standard Mac keyboard has its own real recording (fn aside: no pack records it)."] : []
        parts.append("License: \(license)")
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
    /// Per-key files loaded: every key on a full-size board, with room to spare.
    public static let maxPerKey = 160

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
            // Each file's name is worked out once (sort key and class): a per-key pack has ~90
            // files and the folder is rescanned on every menu open, so a comparator that
            // re-derived names cost megabytes.
            let files = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
                .filter { audioExtensions.contains($0.pathExtension.lowercased()) }
                .map { (url: $0, file: $0.lastPathComponent, stem: $0.deletingPathExtension().lastPathComponent) }
                .sorted { $0.file < $1.file }
            var samples: [KeyClass: [URL]] = [:], releases: [KeyClass: [URL]] = [:], rows: [Int: [URL]] = [:]
            var perKey: [Int: URL] = [:]
            for (f, _, n) in files {
                if n.hasPrefix("up-") {
                    let rest = n.dropFirst(3)
                    if let c = KeyClass.allCases.first(where: { rest.hasPrefix($0.filePrefix + "-") }), (releases[c]?.count ?? 0) < maxVariants {
                        releases[c, default: []].append(f)
                    }
                } else if n.hasPrefix("row"), n.count > 4, let r = Int(String(n.dropFirst(3).prefix(1))), (0...4).contains(r),
                          n.dropFirst(4).hasPrefix("-") {
                    if (rows[r]?.count ?? 0) < maxVariants { rows[r, default: []].append(f) }
                } else if n.hasPrefix("sc"), let code = Int(n.dropFirst(2)), code >= 0, String(code) == n.dropFirst(2) {
                    if perKey[code] == nil, perKey.count < maxPerKey { perKey[code] = f }
                } else if let c = KeyClass.allCases.first(where: { n.hasPrefix($0.filePrefix + "-") }), (samples[c]?.count ?? 0) < maxVariants {
                    samples[c, default: []].append(f)
                }
            }
            guard !(samples[.other] ?? []).isEmpty || !rows.isEmpty || !perKey.isEmpty else { continue }
            let meta = (try? Data(contentsOf: folder.appendingPathComponent("pack.json"))).flatMap { try? JSONDecoder().decode(Meta.self, from: $0) }
            let id = folder.lastPathComponent
            packs.append(SoundPack(id: id, name: meta?.name ?? id, license: meta?.license ?? "unknown",
                                   tier: meta?.tier.flatMap { SoundPack.Tier(rawValue: $0) }.flatMap { $0 == .builtin ? nil : $0 } ?? .local,
                                   attribution: meta?.attribution, samples: samples, rows: rows, perKey: perKey, releases: releases,
                                   folder: folder))
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

/// What a pack's files are right now: every file it plays from, plus its pack.json (which the
/// fetch script rewrites with the download's sha256 on every install), by name, size and
/// modification time. Re-fetched or replaced recordings under the same names change it.
public struct PackFingerprint: Equatable, Sendable {
    public let entries: [String]

    public static func of(_ pack: SoundPack, fileManager fm: FileManager = .default) -> PackFingerprint {
        var urls = pack.files
        if let folder = pack.folder { urls.append(folder.appendingPathComponent("pack.json")) }
        let entries = urls.map { url -> String in
            guard let a = try? fm.attributesOfItem(atPath: url.path) else { return "\(url.lastPathComponent)|missing" }
            let size = (a[.size] as? NSNumber)?.int64Value ?? -1
            let mtime = (a[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? -1
            return "\(url.lastPathComponent)|\(size)|\(mtime)"
        }
        return PackFingerprint(entries: entries.sorted())
    }
}

/// The ★ as decoding found it, per pack loaded this run, keyed to the pack's fingerprint at that
/// load: any change to its files drops the entry (the star goes back to the file names until the
/// pack is loaded again). Memory only.
public struct DecodedStars: Sendable {
    private var entries: [String: (fingerprint: PackFingerprint, everyKey: Bool)] = [:]

    public init() {}

    public mutating func record(_ id: String, fingerprint: PackFingerprint, everyKey: Bool) {
        entries[id] = (fingerprint, everyKey)
    }

    /// Sets `decodedEveryKey` on every pack whose recorded fingerprint still matches its files
    /// (`fingerprint` is asked only for packs with an entry) and drops the stale entries.
    public mutating func apply(to packs: inout [SoundPack], fingerprint: (SoundPack) -> PackFingerprint) {
        for i in packs.indices {
            guard let e = entries[packs[i].id] else { continue }
            if e.fingerprint == fingerprint(packs[i]) {
                packs[i].decodedEveryKey = e.everyKey
            } else {
                entries[packs[i].id] = nil
                packs[i].decodedEveryKey = nil
            }
        }
    }
}

/// The dropdown's typing items, as text. The AppKit side only draws them.
public enum TypingMenu {
    public static let toggleTitle = "Typing sounds"
    public static let profileTitle = "Typing sound"
    public static let openSettings = "Open Input Monitoring settings…"
    public static let openPacksFolder = "Open typing sounds folder"
    public static let toggleTooltip = "Plays a click for every key press, anywhere, and shows your typing speed. Has its own switch: the Sound setting and hiding Navi do not mute it. Which keys you press is never stored."
    public static let quietOnCallsTitle = "Quiet on calls"
    public static let quietOnCallsTooltip = "No clicks while any app is using a microphone (calls, dictation); they come back when it stops. Navi only checks whether a microphone is running. She never listens to it and needs no microphone permission."

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
    public static func rows(enabled: Bool, listener: Listener, secureInput: Bool, callMuted: Bool = false) -> [Row] {
        guard enabled else { return [] }
        var rows: [Row] = [.stats]
        if let n = statusNote(enabled: enabled, listener: listener, secureInput: secureInput, callMuted: callMuted) { rows.append(.note(n)) }
        if listener == .needsPermission { rows.append(.openSettings) }
        return rows
    }

    /// One dim line under the toggle, or nil when all is well.
    /// `callMuted` = *Quiet on calls* is on and a microphone is in use.
    public static func statusNote(enabled: Bool, listener: Listener, secureInput: Bool, callMuted: Bool = false) -> String? {
        guard enabled else { return nil }
        if listener == .needsPermission { return "needs Input Monitoring permission" }
        if secureInput { return "paused · a password field has secure input on" }
        if callMuted { return "quiet · a microphone is in use" }
        return nil
    }

    /// `Typing sound · Cherry KC 1000`.
    public static func profileMenuTitle(_ pack: SoundPack) -> String { "\(profileTitle) · \(pack.name)" }

    /// One dim line under the profile list when any pack is starred.
    public static func everyKeyHint(_ packs: [SoundPack]) -> String? {
        packs.contains(where: \.hasEveryKey) ? "\(SoundPack.everyKeyMark) = a real recording for every key (fn aside)" : nil
    }

    /// Shown when no pack is fetched (only the synth click is available).
    public static func missingPacksNote(_ packs: [SoundPack]) -> String? {
        packs.contains { $0.tier != .builtin } ? nil : "no sound packs fetched → synth click (run keysounds/fetch-keysounds.sh)"
    }

    public static func volumeTitle(_ v: Double) -> String { "Volume \(Int((KeySoundSettings.clamp(v) * 100).rounded()))%" }
}
