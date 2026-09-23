import Foundation

/// Hidden = the floating panel is ordered out. This is NOT sleep: the collector keeps running,
/// thread states keep updating, the menubar Triforce keeps its alert dot — but a hidden fairy
/// makes no pops and no sounds. Design rule: "unless I tell it to go away" — hidden means hidden,
/// so a thread going blocked / needs-input never auto-shows her.
/// TODO: auto-show on blocked/needs-input as an opt-in pref, if ever wanted.
public struct NaviVisibility: Equatable, Sendable {
    public private(set) var hidden: Bool

    public init(hidden: Bool = false) { self.hidden = hidden }

    /// Flips shown ↔ hidden. Returns the new `hidden` value.
    @discardableResult
    public mutating func toggle() -> Bool { hidden.toggle(); return hidden }

    /// Returns true if she was shown (i.e. something changed).
    @discardableResult
    public mutating func hide() -> Bool {
        guard !hidden else { return false }
        hidden = true
        return true
    }

    /// Returns true if she was hidden (i.e. something changed).
    @discardableResult
    public mutating func show() -> Bool {
        guard hidden else { return false }
        hidden = false
        return true
    }

    /// The symbol pop to render for a state change — nil while hidden (nobody to see it).
    public func pop(_ state: NaviState?) -> NaviState? { hidden ? nil : state }

    /// Sounds are swallowed while hidden; `showSound` is the one clip that plays on show.
    public var allowsSound: Bool { !hidden }
    public static let showSound: SoundID = .naviIn

    /// Menubar hover text: the status summary plus ` · hidden` when she is.
    public func tooltip(_ summary: String) -> String { hidden ? summary + " · hidden" : summary }

    // MARK: persistence

    public static let prefsKey = "hidden"

    public init(store: KeyValueStore) { self.init(hidden: store.bool(forKey: NaviVisibility.prefsKey)) }

    public func save(to store: KeyValueStore) { store.set(hidden, forKey: NaviVisibility.prefsKey) }
}

/// The two UserDefaults calls the pet needs, so PetCore stays Foundation-only and tests
/// can use a dictionary.
public protocol KeyValueStore {
    func bool(forKey key: String) -> Bool
    func set(_ value: Bool, forKey key: String)
}

extension UserDefaults: KeyValueStore {}

/// What the menubar Triforce should look like. Pure so the drawing code has nothing to decide:
/// `alert` (anything blocked / needs input) adds the filled dot at the bottom-right;
/// `hidden` dims the whole glyph to 45 % (still a template image, so it follows the menubar theme).
public struct MenubarIconSpec: Equatable, Sendable {
    public static let hiddenOpacity: Double = 0.45
    public var alert: Bool
    public var hidden: Bool

    public init(alert: Bool, hidden: Bool) { self.alert = alert; self.hidden = hidden }

    public init(live: [NaviState], hidden: Bool) {
        self.init(alert: live.contains(.blocked) || live.contains(.needsInput), hidden: hidden)
    }

    public var opacity: Double { hidden ? MenubarIconSpec.hiddenOpacity : 1 }
}
