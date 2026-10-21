import Foundation

// Where each key sits on a standard Mac keyboard (ANSI MacBook layout, plus the nav block and
// keypad of a full-size one). Used in memory only, to pick a key's own sound and its stereo
// position. PRIVACY: nothing here is stored, logged or sent; see KeySounds.swift.

/// One physical key: its keyboard row, the horizontal centre of its cap (in key widths from
/// the left edge of the main block, 0…15), its Mechvibes scancode, and its place in reading order
/// (row by row, left to right), which the fallback sound assignment uses.
public struct KeyGeometry: Equatable, Sendable {
    public let keyCode: UInt16
    /// 0 = F-row and number row, 1 = Q row, 2 = home row, 3 = Z row, 4 = space row, arrows,
    /// nav block and keypad (the rows of per-row `row0…row4` recordings).
    public let row: Int
    public let x: Double
    /// Mechvibes / iohook keycode (PC set-1 scancode, 0xE0-extended keys as 3584+ / 57344+):
    /// the name of a per-key sample in Mechvibes packs (`30.wav` = A). nil = no such key there.
    public let scancode: Int?
    public let order: Int
    /// A wide key or a modifier (`MacKeyboard.bigKeyCodes`).
    public var big: Bool { MacKeyboard.bigKeyCodes.contains(keyCode) }
}

public enum MacKeyboard {
    /// Width of the main block in key widths; space sits at the middle.
    public static let width = 15.0

    // (mac virtual key code, row, x, Mechvibes scancode), in reading order.
    private static let table: [(UInt16, Int, Double, Int?)] = [
        // F-row (row 0, like the number row).
        (53, 0, 0.5, 1),                                            // esc
        (122, 0, 1.6, 59), (120, 0, 2.7, 60), (99, 0, 3.8, 61), (118, 0, 4.9, 62),     // F1–F4
        (96, 0, 6.0, 63), (97, 0, 7.1, 64), (98, 0, 8.2, 65), (100, 0, 9.3, 66),       // F5–F8
        (101, 0, 10.4, 67), (109, 0, 11.5, 68), (103, 0, 12.6, 87), (111, 0, 13.7, 88), // F9–F12
        // Number row.
        (50, 0, 0.5, 41), (10, 0, 0.5, 41),                         // ` (and ISO §)
        (18, 0, 1.5, 2), (19, 0, 2.5, 3), (20, 0, 3.5, 4), (21, 0, 4.5, 5), (23, 0, 5.5, 6),
        (22, 0, 6.5, 7), (26, 0, 7.5, 8), (28, 0, 8.5, 9), (25, 0, 9.5, 10), (29, 0, 10.5, 11),
        (27, 0, 11.5, 12), (24, 0, 12.5, 13),                       // - =
        (51, 0, 14.0, 14),                                          // delete (backspace)
        // Q row.
        (48, 1, 0.75, 15),                                          // tab
        (12, 1, 2.0, 16), (13, 1, 3.0, 17), (14, 1, 4.0, 18), (15, 1, 5.0, 19), (17, 1, 6.0, 20),
        (16, 1, 7.0, 21), (32, 1, 8.0, 22), (34, 1, 9.0, 23), (31, 1, 10.0, 24), (35, 1, 11.0, 25),
        (33, 1, 12.0, 26), (30, 1, 13.0, 27), (42, 1, 14.25, 43),   // [ ] \
        // Home row.
        (57, 2, 0.875, 58),                                         // caps lock
        (0, 2, 2.25, 30), (1, 2, 3.25, 31), (2, 2, 4.25, 32), (3, 2, 5.25, 33), (5, 2, 6.25, 34),
        (4, 2, 7.25, 35), (38, 2, 8.25, 36), (40, 2, 9.25, 37), (37, 2, 10.25, 38), (41, 2, 11.25, 39),
        (39, 2, 12.25, 40), (36, 2, 14.125, 28),                    // ' return
        // Z row.
        (56, 3, 1.125, 42),                                         // left shift
        (6, 3, 2.75, 44), (7, 3, 3.75, 45), (8, 3, 4.75, 46), (9, 3, 5.75, 47), (11, 3, 6.75, 48),
        (45, 3, 7.75, 49), (46, 3, 8.75, 50), (43, 3, 9.75, 51), (47, 3, 10.75, 52), (44, 3, 11.75, 53),
        (60, 3, 13.875, 54),                                        // right shift
        // Space row and arrows.
        (63, 4, 0.5, nil), (59, 4, 1.5, 29), (58, 4, 2.5, 56), (55, 4, 3.625, 3675),   // fn ctrl opt cmd
        (49, 4, 7.5, 57),                                           // space: dead centre
        (54, 4, 11.375, 3676), (61, 4, 12.5, 3640), (62, 4, 12.5, 3613),               // cmd opt ctrl (right)
        (123, 4, 13.5, 57419), (126, 4, 14.5, 57416), (125, 4, 14.5, 57424), (124, 4, 15.5, 57421),
        // Nav block (full-size keyboards), right of the main block.
        (114, 4, 16.0, 3666), (115, 4, 16.5, 3655), (116, 4, 17.0, 3657),             // help/insert home pgup
        (117, 4, 16.0, 3667), (119, 4, 16.5, 3663), (121, 4, 17.0, 3665),             // fwd delete end pgdn
        // Keypad, far right.
        (71, 4, 18.0, 69), (81, 4, 19.0, nil), (75, 4, 20.0, 3637), (67, 4, 21.0, 55),
        (89, 4, 18.0, 71), (91, 4, 19.0, 72), (92, 4, 20.0, 73), (78, 4, 21.0, 74),
        (86, 4, 18.0, 75), (87, 4, 19.0, 76), (88, 4, 20.0, 77), (69, 4, 21.0, 78),
        (83, 4, 18.0, 79), (84, 4, 19.0, 80), (85, 4, 20.0, 81), (76, 4, 21.0, 3612),
        (82, 4, 18.5, 82), (65, 4, 20.0, 83),
        // Added 2026-10-21 so every key of a standard Mac keyboard has a place (appended, so the
        // reading order above, and every sound it picks, stays as it was). No Mechvibes recording.
        (105, 0, 16.0, nil), (107, 0, 16.5, nil), (113, 0, 17.0, nil),                 // F13–F15 (above the nav block)
        (106, 0, 18.0, nil), (64, 0, 19.0, nil), (79, 0, 20.0, nil), (80, 0, 21.0, nil), // F16–F19 (above the keypad)
        (90, 0, 21.0, nil),                                                             // F20
        (93, 0, 13.5, nil), (94, 3, 12.75, nil), (95, 4, 21.0, nil),                   // JIS ¥, _, keypad ,
        (102, 4, 4.5, nil), (104, 4, 10.5, nil), (110, 4, 12.0, nil),                  // JIS 英数, かな; context menu
    ]

    /// Wide keys and modifiers: when a pack has no recording of their own they borrow a big key's
    /// sound (shift, return, space…), never a letter's. Tab, caps lock, both shifts, return,
    /// delete, space, fn and every ⌃ ⌥ ⌘, and the keypad's 0, enter and +.
    public static let bigKeyCodes: Set<UInt16> = [48, 57, 56, 60, 36, 51, 49, 63, 59, 58, 55, 54, 61, 62, 82, 76, 69]

    /// What the profile picker's ★ means: a pack has its own recording for every key of a
    /// standard Mac keyboard in the MacBook layout (esc, F1–F12, the number row, letters,
    /// punctuation, tab, caps lock, return, delete, both shifts, ⌃, both ⌥ and ⌘, space, the
    /// arrows), fn excluded. fn is left out on purpose: it is laptop-only and has no Mechvibes
    /// scancode, so no pack records it and no pack could ever earn the star. The full-size
    /// extras (keypad, nav block, right ⌃, F13+) are not required either.
    public static let starKeyCodes: Set<UInt16> = {
        let notRequired: Set<UInt16> = [10, 62, 114, 115, 116, 117, 119, 121, 63]   // ISO §, right ⌃, nav block, fn
        let mainBlock = table.prefix { $0.0 != 114 }.map(\.0)   // up to the nav block
        return Set(mainBlock).subtracting(notRequired)
    }()

    /// The star rule (`starKeyCodes`) on a set of recordings: per-key ones by Mechvibes scancode,
    /// plus the space / return / delete class recordings, which count for those keys.
    public static func recordsEveryKey(perKey: Set<Int>, classes: Set<KeyClass>) -> Bool {
        guard !perKey.isEmpty else { return false }
        return starKeyCodes.allSatisfy { code in
            let c = KeyEventFilter.keyClass(code)
            if c != .other, classes.contains(c) { return true }
            guard let sc = geometry(code)?.scancode else { return false }
            return perKey.contains(sc)
        }
    }

    /// Indexed by key code (0…127). Built once.
    private static let byCode: [KeyGeometry?] = {
        var out = [KeyGeometry?](repeating: nil, count: 128)
        for (i, (code, row, x, sc)) in table.enumerated() where Int(code) < out.count && out[Int(code)] == nil {
            out[Int(code)] = KeyGeometry(keyCode: code, row: row, x: x, scancode: sc, order: i)
        }
        return out
    }()

    /// nil for a key code that is not on the layout (media keys, JIS extras, codes ≥ 128).
    public static func geometry(_ keyCode: UInt16) -> KeyGeometry? {
        Int(keyCode) < byCode.count ? byCode[Int(keyCode)] : nil
    }

    /// Every key on the layout, in reading order.
    public static var keys: [KeyGeometry] { byCode.compactMap { $0 }.sorted { $0.order < $1.order } }
}

/// Left/right placement by the key's column: left keys lean left, right keys lean right, space
/// is centred. `maxPan` keeps it subtle (an equal-power pan of 0.3 moves the far edge ~2 dB),
/// so headphones are not fatiguing; the keypad and nav block clamp to the right edge.
public enum StereoPan {
    public static let maxPan: Float = 0.3

    public static func pan(x: Double) -> Float {
        let half = MacKeyboard.width / 2
        let t = max(-1, min(1, (x - half) / half))
        return Float(t) * maxPan
    }

    /// 0 for a key that is not on the layout.
    public static func pan(keyCode: UInt16) -> Float {
        MacKeyboard.geometry(keyCode).map { pan(x: $0.x) } ?? 0
    }
}
