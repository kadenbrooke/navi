import AVFoundation
import ObjCGuard
import PetCore

/// Low-latency typing clicks. One `AVAudioEngine` with a pool of player nodes: every pack
/// sample is decoded once, off the main thread, into a preloaded mono buffer (silence trimmed,
/// loudness evened out per class), and a press schedules one buffer on the next voice, so fast
/// typing overlaps clicks. If engine setup raises, the player has no voices and stays silent
/// (fail closed).
///
/// Realism (2026-10-21): at load the pack's `KeySoundPlan` is turned into flat per-key-code
/// tables (press slot, release slot, pan), so a press or release is one array lookup. Every key
/// has its own sound (the pack's per-key / per-row recordings, else a fixed variant + pitch
/// offset), a key-up plays the pack's release or one derived from the press, and each voice is
/// panned by the key's column. Buffers stay mono on purpose: the mixer pans a mono voice into
/// the stereo output (`AVAudioMixing.pan`), which a pre-mixed stereo recording would not allow.
///
/// Not `AVAudioPlayer` (what `SoundPlayer` uses for the menu chimes): one player per sample
/// per voice would mean dozens of audio queues and more start-up lag per click. The engine's
/// risk is the one `SoundPlayer` documents — `AVAudioPlayerNode` raises an Objective-C
/// exception when the output device has no IO — so every engine call goes through
/// `NaviCatchException` and a failure just drops that click. The engine starts on the first
/// press and pauses after `idlePause` seconds without one, so it holds no audio IO while you
/// are away. Measured (M-series, 2026-10-20): a press costs ~0.05 ms on the main thread; a
/// running engine idles at ~0.6 % CPU, paused ~0 %; restarting a paused engine takes ~150 ms,
/// which is why the pause waits 2 minutes (only the first click after a long break is late).
final class KeySoundPlayer {
    static let voices = 10
    static let idlePause: TimeInterval = 120
    /// All clicks share one mono 44.1 kHz format (the mixer converts to the device's).
    static let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    /// Decoding a pack (up to ~100 small files) runs here, never on the main thread.
    private static let decodeQueue = DispatchQueue(label: "dev.navi.pet.keysounds.decode", qos: .userInitiated)

    private let engine = AVAudioEngine()
    private var format: AVAudioFormat { KeySoundPlayer.format }
    /// Only voices that were attached AND connected. Empty = setup failed: the player is inert
    /// (fail closed), every call below is a no-op.
    private var nodes: [AVAudioPlayerNode] = []
    private var live = Loaded.empty
    private var pool = VoicePool(count: 0)
    private var picker = VariantPicker()
    private var rng = SystemRandomNumberGenerator()
    private var running = false
    private var lastPlay: TimeInterval = 0
    private var idleTimer: Timer?
    private var configObserver: NSObjectProtocol?
    private var loggedFailure = false
    private var loads = PackLoadTracker()
    /// The pack whose buffers are live (nil until the first load lands).
    var packID: String? { loads.loadedID }
    /// The pack last asked for (may still be decoding), so callers do not ask twice.
    var requestedID: String? { loads.requestedID }

    /// False when engine setup raised: no voices, no mixer calls, no clicks, no crash.
    var isUsable: Bool { !nodes.isEmpty }

    var volume: Double = 0.5 {
        didSet {
            guard isUsable else { return }
            let v = Float(KeySoundSettings.clamp(volume))
            if let err = NaviCatchException({ [engine] in engine.mainMixerNode.outputVolume = v }) {
                NSLog("Navi: typing sounds volume not set: %@", err)
            }
        }
    }

    init() {
        var attached: [AVAudioPlayerNode] = []
        var connected: [AVAudioPlayerNode] = []
        let v = Float(volume)
        let err = NaviCatchException { [engine, format] in
            for _ in 0..<KeySoundPlayer.voices {
                let n = AVAudioPlayerNode()
                engine.attach(n)
                attached.append(n)
                engine.connect(n, to: engine.mainMixerNode, format: format)
                connected.append(n)   // only after attach + connect both succeeded
            }
            engine.mainMixerNode.outputVolume = v
        }
        if let err {
            // A half-built graph is not trusted: fail closed rather than play on a broken engine,
            // and take the partial graph down now instead of holding it for the process's life.
            NSLog("Navi: typing sounds engine setup failed, typing sounds disabled: %@", err)
            for n in attached {
                if let e = NaviCatchException({ [engine] in engine.detach(n) }) { NSLog("Navi: typing sounds detach failed: %@", e) }
            }
            _ = NaviCatchException { [engine] in engine.stop(); engine.reset() }
            connected = []
        }
        nodes = connected
        pool = VoicePool(count: nodes.count)
        // A device switch (headphones, Bluetooth) stops the engine; the next press restarts it.
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.running = false
        }
    }

    deinit {
        idleTimer?.invalidate()
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        _ = NaviCatchException { [engine] in engine.stop() }
    }

    // MARK: loading

    /// Decodes every sample of `pack` on a background queue and swaps the buffers in on the main
    /// thread when done; until then the previous pack keeps clicking. A newer `load` supersedes
    /// an older one still decoding (its result is dropped). `done` gets the id that went live and
    /// whether the recordings that decoded still record every key (the ★; nil for the synth).
    func load(_ pack: SoundPack, done: ((String, Bool?) -> Void)? = nil) {
        let ticket = loads.request(pack.id)
        KeySoundPlayer.decodeQueue.async { [weak self] in
            let loaded = KeySoundPlayer.decodePack(pack)
            DispatchQueue.main.async {
                guard let self, self.loads.complete(ticket, loadedID: loaded.id) else { return }
                self.live = loaded
                self.generation &+= 1
                done?(loaded.id, loaded.everyKey)
            }
        }
    }

    /// Bumped every time a pack goes live. `KeyPairing` stamps each press with it, so a key held
    /// across a profile switch does not release with the new pack.
    private(set) var generation: UInt32 = 0

    /// A loaded pack: sound slots (one or more variant buffers each) and, per key code 0…127,
    /// which slot a press and a release play and the pan. Codes ≥ 128 have no entry.
    struct Loaded {
        var id: String
        var slots: [[AVAudioPCMBuffer]]
        var press: [Int]
        var release: [Int]
        var pan: [Float]
        /// `MacKeyboard.recordsEveryKey` over what decoded; nil for the synth click.
        var everyKey: Bool? = nil
        static let empty = Loaded(id: "", slots: [], press: [], release: [], pan: [])

    }

    /// Off-main: the pack's samples as preloaded buffers, laid out per key. A pack whose files
    /// all fail to decode falls back to the synth click, with one log line. Pure function of its
    /// input.
    private static func decodePack(_ pack: SoundPack) -> Loaded {
        // Every recording is decoded once, straight into the buffer that plays it (no second
        // copy: a per-key pack is ~90 recordings).
        var id = pack.id
        var generic: [AVAudioPCMBuffer] = [], classes: [KeyClass: [AVAudioPCMBuffer]] = [:], rows: [Int: [AVAudioPCMBuffer]] = [:]
        var perKey: [Int: AVAudioPCMBuffer] = [:], upGeneric: [AVAudioPCMBuffer] = [], upClasses: [KeyClass: [AVAudioPCMBuffer]] = [:]
        let special: [KeyClass] = [.space, .enter, .backspace]
        if pack.tier != .builtin {
            generic = (pack.samples[.other] ?? []).compactMap(decode)
            for c in special {
                let d = (pack.samples[c] ?? []).compactMap(decode)
                if !d.isEmpty { classes[c] = d }
                let u = (pack.releases[c] ?? []).compactMap(decode)
                if !u.isEmpty { upClasses[c] = u }
            }
            upGeneric = (pack.releases[.other] ?? []).compactMap(decode)
            for (r, urls) in pack.rows {
                let d = urls.compactMap(decode)
                if !d.isEmpty { rows[r] = d }
            }
            // Only keys a Mac keyboard has: the rest would be memory for nothing.
            let onLayout = Set(MacKeyboard.keys.compactMap(\.scancode))
            for (sc, url) in pack.perKey where onLayout.contains(sc) {
                if let d = decode(url) { perKey[sc] = d }
            }
            if generic.isEmpty && rows.isEmpty && perKey.isEmpty {
                NSLog("Navi: typing sound pack %@ did not decode → synth click", pack.id)
                id = SoundPack.synth.id
                classes = [:]; upGeneric = []; upClasses = [:]
            }
        }
        if generic.isEmpty && rows.isEmpty && perKey.isEmpty {
            generic = (0..<SynthClick.variants).compactMap { buffer(SynthClick.samples(.other, variant: $0, sampleRate: format.sampleRate)) }
            for c in special {
                classes[c] = (0..<SynthClick.variants).compactMap { buffer(SynthClick.samples(c, variant: $0, sampleRate: format.sampleRate)) }
            }
        }

        // One gain per press group (variants and keys keep their relative loudness): profiles
        // switch without a volume jump, and a pack whose key clicks are recorded far quieter
        // than its space bar (some packs: 0.03 vs 0.29 peak) still clicks. The ordinary keys
        // (generic, per-row and per-key recordings) are one group, so no key stands out.
        func rawPeak(_ set: [AVAudioPCMBuffer]) -> Float { set.map { SampleMath.peak(samples($0)) }.max() ?? 0 }
        func gain(_ set: [AVAudioPCMBuffer], level: Float = 0.8) -> Float {
            let peak = rawPeak(set)
            return peak > 0 ? min(12, level / peak) : 1
        }
        let keyPresses = generic + rows.values.flatMap { $0 } + Array(perKey.values)
        let keyGain = gain(keyPresses)
        var classGain: [KeyClass: Float] = [:]
        for (c, set) in classes { classGain[c] = gain(set) }
        // Pack releases keep their real level against the press, but never above half the
        // press's normalised peak (some packs record their key-ups as loud as their presses).
        func releaseGain(_ ups: [AVAudioPCMBuffer], press: [AVAudioPCMBuffer], pressGain: Float) -> Float {
            min(pressGain, gain(ups, level: 0.5 * pressGain * rawPeak(press)))
        }
        let upGenericGain = releaseGain(upGeneric, press: keyPresses, pressGain: keyGain)
        var upClassGain: [KeyClass: Float] = [:]
        for (c, set) in upClasses {
            upClassGain[c] = releaseGain(set, press: classes[c] ?? keyPresses, pressGain: classGain[c] ?? keyGain)
        }
        // Every recording belongs to exactly one group: scale it in place, once.
        for b in keyPresses { scale(b, keyGain) }
        for (c, set) in classes { set.forEach { scale($0, classGain[c] ?? 1) } }
        for b in upGeneric { scale(b, upGenericGain) }
        for (c, set) in upClasses { set.forEach { scale($0, upClassGain[c] ?? 1) } }

        // The recordings behind a sound. At the recording's own pitch a slot plays the decoded
        // buffer itself; a pitch offset gets its own resampled copy.
        func source(_ sound: KeySoundPlan.Sound) -> [AVAudioPCMBuffer] {
            switch sound.source {
            case .generic(let i): return generic.indices.contains(i) ? [generic[i]] : []
            case .cls(let c): return classes[c] ?? []
            case .row(let r, let v): return (rows[r]?.indices.contains(v) ?? false) ? [rows[r]![v]] : []
            case .perKey(let sc): return perKey[sc].map { [$0] } ?? []
            case .releaseGeneric(let v): return upGeneric.indices.contains(v) ? [upGeneric[v]] : []
            case .releaseClass(let c): return upClasses[c] ?? []
            }
        }
        func buffers(_ sound: KeySoundPlan.Sound) -> [AVAudioPCMBuffer] {
            let rate = KeySoundPlan.rate(detune: sound.detune)
            guard rate != 1 else { return source(sound) }
            return source(sound).compactMap { buffer(SampleMath.varispeed(Array(samples($0)), rate: rate)) }
        }
        func derivedRelease(_ press: KeySoundPlan.Sound) -> [AVAudioPCMBuffer] {
            let pitch = KeySoundPlan.rate(detune: press.detune)
            // Only the attack is used: hand over just the head of the press.
            let head = Int(ReleaseSynth.length * format.sampleRate * ReleaseSynth.rate * pitch) + 4
            return source(press).compactMap {
                buffer(ReleaseSynth.derive(Array(samples($0).prefix(head)), sampleRate: format.sampleRate, pitch: pitch))
            }
        }

        let plan = KeySoundPlan(PackInventory(
            generic: generic.count, classes: classes.mapValues(\.count), rows: rows.mapValues(\.count),
            perKey: Set(perKey.keys), releaseGeneric: upGeneric.count, releaseClasses: upClasses.mapValues(\.count)))

        var slots: [[AVAudioPCMBuffer]] = []
        var pressSlot: [KeySoundPlan.Sound: Int] = [:], releaseSlot: [KeySoundPlan.Release: Int] = [:]
        func slot(_ bufs: [AVAudioPCMBuffer]) -> Int {
            slots.append(bufs)
            return slots.count - 1
        }
        func pressIndex(_ s: KeySoundPlan.Sound) -> Int {
            if let i = pressSlot[s] { return i }
            let i = slot(buffers(s)); pressSlot[s] = i; return i
        }
        func releaseIndex(_ r: KeySoundPlan.Release) -> Int {
            if let i = releaseSlot[r] { return i }
            let i: Int
            switch r {
            case .pack(let s): i = slot(buffers(s))
            case .derived(let p): i = slot(derivedRelease(p))
            }
            releaseSlot[r] = i; return i
        }
        let voices = plan.voices
        let press = voices.map { pressIndex($0.press) }
        let release = voices.map { releaseIndex($0.release) }
        let everyKey = id == SoundPack.synth.id ? nil
            : MacKeyboard.recordsEveryKey(perKey: Set(perKey.keys), classes: Set(classes.keys))
        return Loaded(id: id, slots: slots, press: press, release: release, pan: voices.map(\.pan), everyKey: everyKey)
    }

    /// Any CoreAudio-readable file → mono 44.1 kHz floats, near-silence trimmed off both ends.
    /// Each file in its own autorelease pool: a pack decodes in one dispatch block, and a
    /// per-key pack has ~90 files, so their AVAudioFile / converter objects must not pile up.
    private static func decode(_ url: URL) -> AVAudioPCMBuffer? {
        autoreleasepool { decodeFile(url) }
    }

    private static func decodeFile(_ url: URL) -> AVAudioPCMBuffer? {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0, file.length < 10 * 48_000 else { return nil }
        let inFormat = file.processingFormat
        guard let input = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: input)) != nil,
              let converter = AVAudioConverter(from: inFormat, to: format) else { return nil }
        converter.downmix = true
        let capacity = AVAudioFrameCount(Double(input.frameLength) * format.sampleRate / inFormat.sampleRate) + 4096
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inStatus in
            if fed { inStatus.pointee = .endOfStream; return nil }
            fed = true
            inStatus.pointee = .haveData
            return input
        }
        guard status != .error, error == nil, let ch = out.floatChannelData else { return nil }
        let all = UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength))
        let keep = SampleTrim.range(all, sampleRate: format.sampleRate)
        return keep.isEmpty ? nil : buffer(UnsafeBufferPointer(rebasing: all[keep]))
    }

    /// An exact-size mono buffer holding `s`.
    private static func buffer<C: Collection>(_ s: C) -> AVAudioPCMBuffer? where C.Element == Float {
        guard !s.isEmpty, let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(s.count)),
              let ch = b.floatChannelData else { return nil }
        b.frameLength = AVAudioFrameCount(s.count)
        _ = UnsafeMutableBufferPointer(start: ch[0], count: s.count).initialize(from: s)
        return b
    }

    private static func samples(_ b: AVAudioPCMBuffer) -> UnsafeBufferPointer<Float> {
        UnsafeBufferPointer(start: b.floatChannelData?[0], count: Int(b.frameLength))
    }

    private static func scale(_ b: AVAudioPCMBuffer, _ g: Float) {
        guard g != 1, let ch = b.floatChannelData else { return }
        for i in 0..<Int(b.frameLength) { ch[0][i] *= g }
    }

    // MARK: playback

    /// The key's press sound, panned by its column. True only when it was actually scheduled:
    /// false with no usable engine, no pack loaded yet, a key code ≥ 128, or a schedule that
    /// raised (a dead output drops the click, never crashes). The key code is an index into
    /// the precomputed tables and goes nowhere else.
    @discardableResult
    func press(_ keyCode: UInt16) -> Bool {
        let i = Int(keyCode)
        guard i < live.press.count else { return false }
        return play(slot: live.press[i], pan: live.pan[i])
    }

    /// The key's release sound (softer), at the same pan. The caller pairs it with a press.
    @discardableResult
    func release(_ keyCode: UInt16) -> Bool {
        let i = Int(keyCode)
        guard i < live.release.count else { return false }
        return play(slot: live.release[i], pan: live.pan[i])
    }

    private func play(slot: Int, pan: Float) -> Bool {
        guard isUsable, slot < live.slots.count, !live.slots[slot].isEmpty, wake(),
              let voice = pool.take(), voice < nodes.count else { return false }
        let set = live.slots[slot]
        let buf = set.count == 1 ? set[0] : set[picker.pick(slot, count: set.count, using: &rng)]
        let node = nodes[voice]
        let jitter = Float.random(in: 0.85...1, using: &rng)
        if let err = NaviCatchException({
            node.volume = jitter
            node.pan = pan
            node.scheduleBuffer(buf, at: nil, options: .interrupts, completionHandler: nil)
        }) {
            running = false
            if !loggedFailure { loggedFailure = true; NSLog("Navi: typing click dropped: %@", err) }
            return false
        }
        lastPlay = ProcessInfo.processInfo.systemUptime
        return true
    }

    /// Starts the engine and the voices if they are not running. False = no audio right now.
    private func wake() -> Bool {
        guard isUsable else { return false }
        if running && engine.isRunning { return true }
        var ok = false
        let err = NaviCatchException { [self] in
            if !engine.isRunning {
                engine.prepare()
                do { try engine.start() } catch { NSLog("Navi: typing sounds engine did not start: %@", "\(error)"); return }
            }
            for n in nodes { n.play() }
            ok = true
        }
        if let err { NSLog("Navi: typing sounds engine start raised: %@", err) }
        running = ok
        if ok { loggedFailure = false; armIdleTimer() }
        return ok
    }

    /// Checks every 5 s while running; pauses the engine after `idlePause` quiet seconds.
    private func armIdleTimer() {
        guard idleTimer == nil else { return }
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            if ProcessInfo.processInfo.systemUptime - self.lastPlay >= KeySoundPlayer.idlePause { self.pause() }
        }
        t.tolerance = 2
        RunLoop.main.add(t, forMode: .common)
        idleTimer = t
    }

    func pause() {
        idleTimer?.invalidate(); idleTimer = nil
        guard isUsable else { return }
        _ = NaviCatchException { [self] in
            for n in nodes { n.stop() }
            engine.pause()
        }
        running = false
    }
}
