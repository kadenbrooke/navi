import AppKit
import PetCore

/// Draws `MenubarDropdown` items as native NSMenuItems. All text and colors come from
/// PetCore; this file only picks fonts. Info rows (usage) stay enabled with no
/// action so they read at full contrast; headers and notes are disabled.
enum StatusMenuRenderer {
    static let idleOpacity: CGFloat = MenuRowView.idleOpacity

    /// `onThread` is the selector a thread item sends; its `representedObject` is the thread id.
    static func items(_ items: [MenubarDropdown.Item], target: AnyObject, onThread: Selector) -> [NSMenuItem] {
        items.map { item in
            switch item {
            case .header(let t):
                return NSMenuItem.sectionHeader(title: t)
            case .separator:
                return .separator()
            case .note(let t):
                let m = NSMenuItem(title: t, action: nil, keyEquivalent: "")
                m.attributedTitle = NSAttributedString(string: t, attributes: [.font: mono(10), .foregroundColor: NSColor.secondaryLabelColor])
                m.isEnabled = false
                return m
            case .thread(let l):
                let m = NSMenuItem(title: l.name, action: onThread, keyEquivalent: "")
                m.target = target
                m.representedObject = l.id
                m.attributedTitle = twoLines(l.name, right: l.stateText, below: l.status, dim: l.idle ? idleOpacity : 1)
                m.image = dot(l.hex, alpha: l.idle ? idleOpacity : 1)
                m.toolTip = [l.fullStatus, l.opensIn.map { "Click: \($0)" } ?? ""].filter { !$0.isEmpty }.joined(separator: "\n\n")
                if m.toolTip?.isEmpty == true { m.toolTip = nil }
                return m
            case .usage(let u):
                let m = NSMenuItem(title: u.label, action: nil, keyEquivalent: "")
                var headAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium)]
                if u.error != nil { headAttrs[.foregroundColor] = NSColor.secondaryLabelColor }
                else if u.blocked { headAttrs[.foregroundColor] = MenuTheme.color(UsageBar.red) }
                let head = NSMutableAttributedString(string: u.label, attributes: headAttrs)
                if u.blocked && u.error == nil { head.append(NSAttributedString(string: "  !", attributes: [.font: mono(12, .bold), .foregroundColor: MenuTheme.color(UsageBar.red)])) }
                if let err = u.error { head.append(NSAttributedString(string: "  \(err)", attributes: [.font: mono(10), .foregroundColor: NSColor.secondaryLabelColor])) }
                for line in u.lines {
                    head.append(NSAttributedString(string: "\n" + line, attributes: [.font: mono(10), .foregroundColor: NSColor.secondaryLabelColor]))
                }
                m.attributedTitle = head
                m.image = u.hex.map { dot($0, alpha: 1) } ?? dot(nil, alpha: 1)
                m.toolTip = u.tooltip
                return m
            }
        }
    }

    /// `name   ⟳ working` over a smaller status line. The main line only gets a color when
    /// dimmed: an explicit labelColor loses the menu's vibrant text and reads washed out.
    private static func twoLines(_ main: String, right: String, below: String, dim: CGFloat) -> NSAttributedString {
        var mainAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium)]
        if dim < 1 { mainAttrs[.foregroundColor] = NSColor.secondaryLabelColor.withAlphaComponent(dim + 0.2) }
        let t = NSMutableAttributedString(string: main, attributes: mainAttrs)
        if !right.isEmpty {
            t.append(NSAttributedString(string: "   " + right, attributes: [.font: mono(11), .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(dim)]))
        }
        if !below.isEmpty {
            t.append(NSAttributedString(string: "\n" + below, attributes: [.font: mono(10), .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(dim)]))
        }
        return t
    }

    private static func mono(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont { .monospacedSystemFont(ofSize: size, weight: weight) }

    /// The state-color dot, same colors as the fairy menu's row dots. nil hex = an empty slot
    /// of the same width so titles line up.
    static func dot(_ hex: String?, alpha: CGFloat) -> NSImage {
        let img = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { r in
            guard let hex else { return true }
            MenuTheme.color(hex).withAlphaComponent(alpha).setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        img.isTemplate = false
        return img
    }
}
