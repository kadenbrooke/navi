import XCTest
@testable import PetCore

final class SoundPackTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("navi-packs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// A pack folder with empty placeholder "audio" files (scanning never decodes).
    func makePack(_ id: String, files: [String], meta: String? = nil) throws {
        let p = dir.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: p, withIntermediateDirectories: true)
        for f in files { try Data().write(to: p.appendingPathComponent(f)) }
        if let meta { try Data(meta.utf8).write(to: p.appendingPathComponent("pack.json")) }
    }

    func testScanOrdersPublicThenLocalThenSynth() throws {
        try makePack("zeta", files: ["key-01.wav"], meta: #"{"name":"Zeta","license":"unknown","tier":"local"}"#)
        try makePack("cherry", files: ["key-01.wav", "key-02.wav"], meta: #"{"name":"Cherry KC 1000","license":"CC0","tier":"public"}"#)
        try makePack("alpha", files: ["key-01.mp3"], meta: #"{"name":"Alpha","license":"MIT","tier":"local"}"#)
        let packs = SoundPackLibrary.scan(dir)
        XCTAssertEqual(packs.map(\.id), ["cherry", "alpha", "zeta", "synth"])
        XCTAssertEqual(packs[0].tier, .public)
        XCTAssertEqual(packs[0].license, "CC0")
        XCTAssertEqual(packs[0].samples[.other]?.map(\.lastPathComponent), ["key-01.wav", "key-02.wav"])
    }

    func testClassesFallBackToKeySamples() throws {
        try makePack("p", files: ["key-01.wav", "space-01.wav", "space-02.mp3", "backspace-01.flac"])
        let p = try XCTUnwrap(SoundPackLibrary.scan(dir).first)
        XCTAssertEqual(p.samples(for: .space).map(\.lastPathComponent), ["space-01.wav", "space-02.mp3"])
        XCTAssertEqual(p.samples(for: .backspace).map(\.lastPathComponent), ["backspace-01.flac"])
        XCTAssertEqual(p.samples(for: .enter).map(\.lastPathComponent), ["key-01.wav"], "no enter samples → key samples")
    }

    func testBrokenOrIncompletePacksAreSkippedNeverThrow() throws {
        try makePack("no-keys", files: ["space-01.wav", "readme.txt"], meta: #"{"name":"No keys"}"#)
        try makePack("half.part", files: ["key-01.wav"])                     // a fetch in progress
        try makePack("not-audio", files: ["key-01.txt", "key-02.json"])
        try makePack("bad-meta", files: ["key-01.wav"], meta: "{oops")
        try makePack("builtin-claim", files: ["key-01.wav"], meta: #"{"tier":"builtin"}"#)
        try Data().write(to: dir.appendingPathComponent("stray-file.wav"))
        let packs = SoundPackLibrary.scan(dir)
        XCTAssertEqual(packs.map(\.id), ["bad-meta", "builtin-claim", "synth"])
        XCTAssertEqual(packs[0].name, "bad-meta", "unreadable pack.json → named after its folder")
        XCTAssertEqual(packs[0].tier, .local, "unknown license is never treated as public")
        XCTAssertEqual(packs[1].tier, .local, "only the code's own synth is built-in")
    }

    func testMissingFolderGivesSynthOnly() {
        let packs = SoundPackLibrary.scan(dir.appendingPathComponent("nope"))
        XCTAssertEqual(packs, [SoundPack.synth])
        XCTAssertNotNil(TypingMenu.missingPacksNote(packs))
    }

    func testVariantsAreCapped() throws {
        try makePack("big", files: (1...50).map { String(format: "key-%02d.wav", $0) })
        XCTAssertEqual(SoundPackLibrary.scan(dir).first?.samples[.other]?.count, SoundPackLibrary.maxVariants)
    }

    /// The committed public manifest: each id safe as a folder name, names unique, every download
    /// pinned, and every map class one the fetch script and the scanner know. Reads
    /// keysounds/packs-public.tsv from the repo.
    func testPublicManifestIsClean() throws {
        let keysounds = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("keysounds", isDirectory: true)
        let text = try String(contentsOf: keysounds.appendingPathComponent("packs-public.tsv"), encoding: .utf8)
        var ids: [String] = [], names: [String] = []
        for line in text.split(separator: "\n") where !line.hasPrefix("#") && !line.isEmpty {
            let c = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            XCTAssertEqual(c.count, 8, "8 tab-separated columns: \(line)")
            guard c.count == 8 else { continue }
            let (id, name, url, sha, map) = (c[0], c[1], c[5], c[6], c[7])
            XCTAssertNotNil(id.range(of: #"^[a-z0-9][a-z0-9-]{0,63}$"#, options: .regularExpression), "id: \(id)")
            XCTAssertNotNil(sha.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression), "sha256 pin: \(id)")
            XCTAssertTrue(url.hasPrefix("https://"), "https only: \(id)")
            let classes = map.split(separator: ";").map { String($0.split(separator: ":")[0]) }
            XCTAssertTrue(classes.contains { $0 == "key" || $0.hasPrefix("row") || $0.hasPrefix("sc") }, "press samples mapped: \(id)")
            for c in classes {
                XCTAssertNotNil(c.range(of: #"^(key|space|enter|backspace|up-key|up-space|up-enter|up-backspace|row[0-4]|sc|sc[0-9]{1,5})$"#,
                                        options: .regularExpression), "known map class \(c): \(id)")
            }
            ids.append(id); names.append(name)
        }
        XCTAssertFalse(ids.isEmpty, "the public manifest lists packs")
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate pack id")
        XCTAssertEqual(Set(names.map { $0.lowercased() }).count, names.count, "duplicate pack name")
    }

    func testResolveFallsBack() {
        let a = SoundPack(id: "a", name: "A", license: "CC0", tier: .public, samples: [.other: [URL(fileURLWithPath: "/a")]])
        let b = SoundPack(id: "b", name: "B", license: "x", tier: .local, samples: [.other: [URL(fileURLWithPath: "/b")]])
        let all = [a, b, .synth]
        XCTAssertEqual(SoundPackLibrary.resolve("b", in: all).id, "b")
        XCTAssertEqual(SoundPackLibrary.resolve("synth", in: all).id, "synth", "the synth can be chosen on purpose")
        XCTAssertEqual(SoundPackLibrary.resolve(nil, in: all).id, "a", "default = first fetched pack")
        XCTAssertEqual(SoundPackLibrary.resolve("deleted-pack", in: all).id, "a", "a removed pack falls back, never crashes")
        XCTAssertEqual(SoundPackLibrary.resolve("deleted-pack", in: [.synth]).id, "synth")
        XCTAssertEqual(SoundPackLibrary.resolve(nil, in: []).id, "synth")
    }

    func testMenuText() {
        let pub = SoundPack(id: "c", name: "Cherry KC 1000", license: "CC0", tier: .public, attribution: "by unicaegames")
        let mine = SoundPack(id: "m", name: "My Pack", license: "unknown", tier: .local)
        XCTAssertEqual(pub.menuTitle, "Cherry KC 1000 · CC0")
        XCTAssertEqual(mine.menuTitle, "My Pack · local")
        XCTAssertEqual(SoundPack.synth.menuTitle, "Synth click · built-in")
        XCTAssertTrue(pub.tooltip.contains("by unicaegames"))
        XCTAssertTrue(mine.tooltip.contains("never redistributed"))
        XCTAssertEqual(TypingMenu.profileMenuTitle(mine), "Typing sound · My Pack")
        XCTAssertNil(TypingMenu.missingPacksNote([pub, .synth]))
        XCTAssertEqual(TypingMenu.volumeTitle(0.456), "Volume 46%")
    }

    func testWPMLineAndStatusNotes() {
        XCTAssertEqual(TypingMenu.wpmLine(live: 0, today: TypingStats(day: "d")), "⌨ 0 wpm · nothing typed today")
        XCTAssertEqual(TypingMenu.wpmLine(live: 72, today: TypingStats(day: "d", keystrokes: 600, activeSeconds: 120, bestWPM: 95)),
                       "⌨ 72 wpm · today best 95 · avg 60")
        XCTAssertEqual(TypingMenu.wpmLine(live: 30, today: TypingStats(day: "d", keystrokes: 8, activeSeconds: 2)), "⌨ 30 wpm · 8 keys today")

        XCTAssertNil(TypingMenu.statusNote(enabled: false, listener: .off, secureInput: true), "off: nothing to say")
        XCTAssertEqual(TypingMenu.statusNote(enabled: true, listener: .needsPermission, secureInput: false),
                       "needs Input Monitoring permission")
        XCTAssertEqual(TypingMenu.statusNote(enabled: true, listener: .running, secureInput: true),
                       "paused · a password field has secure input on")
        XCTAssertNil(TypingMenu.statusNote(enabled: true, listener: .running, secureInput: false))
    }

    func testStatsRowShowsEvenWithoutPermission() {
        XCTAssertEqual(TypingMenu.rows(enabled: false, listener: .off, secureInput: false), [])
        XCTAssertEqual(TypingMenu.rows(enabled: true, listener: .needsPermission, secureInput: false),
                       [.stats, .note("needs Input Monitoring permission"), .openSettings],
                       "saved stats stay readable alongside the permission notice")
        XCTAssertEqual(TypingMenu.rows(enabled: true, listener: .running, secureInput: false), [.stats])
    }

    func testCopySaysTypingSoundsHaveTheirOwnSwitch() {
        XCTAssertTrue(TypingMenu.toggleTooltip.contains("own switch"))
        XCTAssertTrue(TypingMenu.toggleTooltip.contains("do not mute"))
        XCTAssertTrue(MenubarDropdown.soundTooltip.contains("Typing sounds have their own switch"))
    }
}
