import AVFoundation
import PetCore

/// Plays Navi's sounds. No audio ships with Navi: clips are your own files in `Paths.sfxDir`
/// (`~/Library/Application Support/Navi/sfx/` by default), named `<SoundID>.<ext>` — see
/// README → Sounds. Any clip that is missing or fails to decode is simply silent, with one
/// log line. Never throws, never crashes.
final class SoundPlayer {
    private let engine = AVAudioEngine()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private var players: [AVAudioPlayerNode] = []
    private var next = 0
    private var buffers: [SoundID: AVAudioPCMBuffer] = [:]
    private(set) var missing: [SoundID] = []
    private var started = false

    /// Per-clip gain (`menu-close` a little quieter).
    private static let gains: [SoundID: Float] = [.menuClose: 0.6]

    init() {
        for _ in 0..<4 {
            let p = AVAudioPlayerNode()
            engine.attach(p)
            engine.connect(p, to: engine.mainMixerNode, format: format)
            players.append(p)
        }
        load()
    }

    /// Extensions tried, in order, for each clip (anything AVAudioFile can read).
    static let extensions = ["wav", "aiff", "aif", "caf", "m4a", "mp3"]

    private func load() {
        for id in SoundID.allCases {
            let urls = SoundPlayer.extensions.map { Paths.sfxDir.appendingPathComponent("\(id.rawValue).\($0)") }
            if let buf = urls.lazy.filter({ FileManager.default.fileExists(atPath: $0.path) }).compactMap({ try? self.decode($0) }).first {
                buffers[id] = buf
            } else {
                missing.append(id)
            }
        }
        if !missing.isEmpty {
            NSLog("Navi: no sound file for %@ in %@ — those stay silent (README → Sounds)",
                  missing.map(\.rawValue).joined(separator: ", "), Paths.sfxDir.path)
        }
    }

    /// Reads a wav and converts it to the engine's mono 44.1k float format.
    private func decode(_ url: URL) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: url)
        guard let raw = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw NSError(domain: "sfx", code: 1)
        }
        try file.read(into: raw)
        guard let conv = AVAudioConverter(from: file.processingFormat, to: format) else { throw NSError(domain: "sfx", code: 2) }
        let ratio = format.sampleRate / file.processingFormat.sampleRate
        let outCap = AVAudioFrameCount(Double(raw.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: outCap) else { throw NSError(domain: "sfx", code: 3) }
        var consumed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true; status.pointee = .haveData; return raw
        }
        if let err { throw err }
        return out
    }

    // MARK: playback

    func play(_ id: SoundID) {
        guard let buf = buffers[id] else { return }
        if !started {
            do { try engine.start(); started = true } catch { NSLog("Navi: audio engine failed: \(error)"); return }
        }
        let p = players[next % players.count]; next += 1
        p.stop()
        p.volume = SoundPlayer.gains[id] ?? 1
        p.scheduleBuffer(buf, at: nil, options: [], completionHandler: nil)
        p.play()
    }
}
