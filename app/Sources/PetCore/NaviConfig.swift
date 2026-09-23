import Foundation

/// Every tunable of the fairy. Defaults are the original design's picks (the design mock's `NAVI`).
/// Field names match the mock's `params` object exactly so a config JSON copied from the
/// playground's Share box can be pasted straight into the app.
public struct NaviParams: Codable, Equatable, Sendable {
    public var size: Double = 7
    public var glowRadius: Double = 4
    public var glowIntensity: Double = 0.55
    public var coreColor: String = "#fff8ad"          // "Working color"
    public var wingCount: Int = 4
    public var wingSpeed: Double = 18.5
    public var wingOpacity: Double = 0.42
    public var wingSize: Double = 1
    public var halo: Bool = false
    public var ring: Bool = false
    public var pixel: Bool = true
    public var pixelSize: Double = 3
    public var geometric: Bool = false
    public var bobAmp: Double = 40
    public var bobFreq: Double = 0.25
    public var followLag: Double = 1
    public var orbitRadius: Double = 320
    public var speed: Double = 2.65
    public var trailLength: Double = 0.35
    public var trailDensity: Double = 11
    public var trailSpread: Double = 22
    public var sound: Bool = true
    public var sleepMin: Double = 10                  // minutes with no state change before she naps

    public init() {}

    /// Lenient: every key optional, unknown keys ignored, so a partial or older JSON never fails.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func num(_ k: CodingKeys, _ d: Double) -> Double {
            if let v = try? c.decode(Double.self, forKey: k) { return v }
            if let v = try? c.decode(Int.self, forKey: k) { return Double(v) }
            return d
        }
        func bool(_ k: CodingKeys, _ d: Bool) -> Bool { (try? c.decode(Bool.self, forKey: k)) ?? d }
        size = num(.size, size); glowRadius = num(.glowRadius, glowRadius); glowIntensity = num(.glowIntensity, glowIntensity)
        coreColor = (try? c.decode(String.self, forKey: .coreColor)) ?? coreColor
        wingCount = Int(num(.wingCount, Double(wingCount)))
        wingSpeed = num(.wingSpeed, wingSpeed); wingOpacity = num(.wingOpacity, wingOpacity); wingSize = num(.wingSize, wingSize)
        halo = bool(.halo, halo); ring = bool(.ring, ring); pixel = bool(.pixel, pixel); geometric = bool(.geometric, geometric)
        pixelSize = num(.pixelSize, pixelSize)
        bobAmp = num(.bobAmp, bobAmp); bobFreq = num(.bobFreq, bobFreq); followLag = num(.followLag, followLag)
        orbitRadius = num(.orbitRadius, orbitRadius); speed = num(.speed, speed)
        trailLength = num(.trailLength, trailLength); trailDensity = num(.trailDensity, trailDensity); trailSpread = num(.trailSpread, trailSpread)
        sound = bool(.sound, sound); sleepMin = num(.sleepMin, sleepMin)
    }
}

public enum MenuSort: String, Codable, Sendable {
    case recent, status
    public var toggled: MenuSort { self == .recent ? .status : .recent }
}

/// The mock's Share-box shape: `{ preset, mode, menuSort, params, workflows }`. `workflows`
/// and the round-1 `status` key are accepted and ignored. Stored in Prefs as one JSON blob.
public struct NaviConfig: Equatable, Sendable {
    public var preset: String = "navi"
    public var mode: String = "follow"
    public var menuSort: MenuSort = .recent
    public var params = NaviParams()

    public init() {}

    private struct Wire: Codable {
        var preset: String?
        var mode: String?
        var menuSort: String?
        var params: NaviParams?
    }

    public static func decode(_ data: Data) throws -> NaviConfig {
        let w = try JSONDecoder().decode(Wire.self, from: data)
        var c = NaviConfig()
        if let p = w.preset, !p.isEmpty { c.preset = p == "nava" ? "navi" : p }
        if let m = w.mode, !m.isEmpty { c.mode = m }
        if let s = w.menuSort, let ms = MenuSort(rawValue: s) { c.menuSort = ms }
        if let p = w.params { c.params = p }
        else {
            // Bare params object pasted without the wrapper: accept that too.
            let bare = try JSONDecoder().decode(NaviParams.self, from: data)
            if (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["size"] != nil { c.params = bare }
        }
        return c
    }

    public func encode() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(Wire(preset: preset, mode: mode, menuSort: menuSort.rawValue, params: params))
    }
}
