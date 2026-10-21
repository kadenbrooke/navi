import AVFoundation
import ObjCGuard
import PetCore

/// Low-latency typing clicks. One `AVAudioEngine` with a pool of player nodes: every pack
/// sample is decoded once, off the main thread, into a preloaded mono buffer (silence trimmed,
/// loudness evened out per class),
/// and a press schedules one buffer on the next voice, so fast typing overlaps clicks.
/// If engine setup raises, the player has no voices and stays silent (fail closed).
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
    private var buffers: [KeyClass: [AVAudioPCMBuffer]] = [:]
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
    /// an older one still decoding (its result is dropped). `done` gets the id that went live.
    func load(_ pack: SoundPack, done: ((String) -> Void)? = nil) {
        let ticket = loads.request(pack.id)
        KeySoundPlayer.decodeQueue.async { [weak self] in
            let (id, decoded) = KeySoundPlayer.decodePack(pack)
            DispatchQueue.main.async {
                guard let self, self.loads.complete(ticket, loadedID: id) else { return }
                self.buffers = decoded
                done?(id)
            }
        }
    }

    /// Off-main: the pack's samples as preloaded buffers. A pack whose files all fail to decode
    /// falls back to the synth click, with one log line. Pure function of its input.
    private static func decodePack(_ pack: SoundPack) -> (String, [KeyClass: [AVAudioPCMBuffer]]) {
        var raw: [KeyClass: [[Float]]] = [:]
        var id = pack.id
        if pack.tier != .builtin {
            for c in KeyClass.allCases {
                guard pack.samples[c] != nil || c == .other else { continue }
                let decoded = pack.samples(for: c).compactMap(decode)
                if !decoded.isEmpty { raw[c] = decoded }
            }
            if raw[.other] == nil {
                NSLog("Navi: typing sound pack %@ did not decode → synth click", pack.id)
                raw = [:]
                id = SoundPack.synth.id
            }
        }
        if raw.isEmpty {
            for c in KeyClass.allCases {
                raw[c] = (0..<SynthClick.variants).map { SynthClick.samples(c, variant: $0, sampleRate: format.sampleRate) }
            }
        }
        // One gain per class (variants keep their relative loudness): profiles switch without a
        // volume jump, and a pack whose key clicks are recorded far quieter than its space bar
        // (some packs: 0.03 vs 0.29 peak) still clicks.
        let buffers = raw.mapValues { set in
            let peak = set.map { s in s.reduce(0) { max($0, abs($1)) } }.max() ?? 0
            let gain: Float = peak > 0 ? min(12, 0.8 / peak) : 1
            return set.compactMap { buffer($0.map { $0 * gain }) }
        }
        return (id, buffers)
    }

    /// Any CoreAudio-readable file → mono 44.1 kHz floats, near-silence trimmed off both ends.
    private static func decode(_ url: URL) -> [Float]? {
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
        let all = Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
        let keep = SampleTrim.range(all, sampleRate: format.sampleRate)
        return keep.isEmpty ? nil : Array(all[keep])
    }

    private static func buffer(_ s: [Float]) -> AVAudioPCMBuffer? {
        guard !s.isEmpty, let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(s.count)),
              let ch = b.floatChannelData else { return nil }
        b.frameLength = AVAudioFrameCount(s.count)
        s.withUnsafeBufferPointer { ch[0].update(from: $0.baseAddress!, count: s.count) }
        return b
    }

    // MARK: playback

    /// One click for a press of class `c`. Never throws; a dead output drops the click.
    func play(_ c: KeyClass) {
        guard isUsable, let set = buffers[c] ?? buffers[.other], !set.isEmpty, wake(),
              let voice = pool.take(), voice < nodes.count else { return }
        let buf = set[picker.pick(c, count: set.count, using: &rng)]
        let node = nodes[voice]
        let jitter = Float.random(in: 0.85...1, using: &rng)
        if let err = NaviCatchException({
            node.volume = jitter
            node.scheduleBuffer(buf, at: nil, options: .interrupts, completionHandler: nil)
        }) {
            running = false
            if !loggedFailure { loggedFailure = true; NSLog("Navi: typing click dropped: %@", err) }
        }
        lastPlay = ProcessInfo.processInfo.systemUptime
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
