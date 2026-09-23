import AppKit
import PetCore

/// Navi's menu: a dark, borderless, non-activating panel that still takes keyboard input
/// (↑↓ move · ←→ page · Tab sort · Enter select · Esc close). Port of the design mock §10's
/// popover. All paging/cursor/sort math lives in `MenuModel` (PetCore); this file is chrome.
final class MenuController {
    static let width: CGFloat = 360
    static let rowHeight: CGFloat = 46

    private(set) var model: MenuModel
    private let panel: MenuPanel
    private let container = MenuContainerView()
    private let title = NSTextField(labelWithString: "build threads · ↑↓ ←→ ⇥ ⏎ esc")
    private let sortButton = MenuTextButton(title: "⇅ recent")
    private let closeButton = MenuTextButton(title: "✕")
    private let rowsStack = NSStackView()
    private let pager = NSStackView()
    private let pagerLabel = NSTextField(labelWithString: "")
    private let prevButton = MenuTextButton(title: "◂")
    private let nextButton = MenuTextButton(title: "▸")
    private let sortNote = NSTextField(labelWithString: "")
    private var outsideMonitor: Any?
    private var threadsById: [String: BuildThread] = [:]
    /// nil until the collector has ever written `usage[]` (older collector / first run).
    private var hasUsageData = false
    private var usagePolledAt: String?

    var onSound: ((SoundID) -> Void)?
    var onSelect: ((MenuRow, BuildThread?) -> Void)?
    var onSortChanged: ((MenuSort) -> Void)?
    var onClosed: (() -> Void)?

    var isOpen: Bool { model.isOpen }

    init(sort: MenuSort) {
        model = MenuModel(sort: sort)
        panel = MenuPanel(contentRect: NSRect(x: 0, y: 0, width: MenuController.width, height: 200))
        panel.contentView = container
        panel.onKey = { [weak self] e in self?.handleKey(e) ?? false }
        panel.onResignKey = { [weak self] in self?.close() }
        buildChrome()
    }

    // MARK: chrome

    private func buildChrome() {
        title.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        title.textColor = MenuTheme.fg3
        sortButton.onClick = { [weak self] in self?.toggleSort() }
        closeButton.onClick = { [weak self] in self?.close() }

        let header = NSStackView(views: [title, NSView(), sortButton, closeButton])
        header.orientation = .horizontal
        header.spacing = 8
        header.edgeInsets = NSEdgeInsets(top: 2, left: 6, bottom: 6, right: 6)

        rowsStack.orientation = .vertical
        rowsStack.spacing = 0
        rowsStack.alignment = .leading

        prevButton.onClick = { [weak self] in self?.turn(-1) }
        nextButton.onClick = { [weak self] in self?.turn(1) }
        pagerLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        pagerLabel.textColor = MenuTheme.fg2
        sortNote.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        sortNote.textColor = MenuTheme.fg3
        pager.orientation = .horizontal
        pager.spacing = 10
        pager.alignment = .centerY
        pager.addArrangedSubview(NSView())
        pager.addArrangedSubview(prevButton)
        pager.addArrangedSubview(pagerLabel)
        pager.addArrangedSubview(nextButton)
        pager.addArrangedSubview(sortNote)
        pager.addArrangedSubview(NSView())
        pager.edgeInsets = NSEdgeInsets(top: 6, left: 0, bottom: 2, right: 0)

        let root = NSStackView(views: [header, rowsStack, pager])
        root.orientation = .vertical
        root.spacing = 0
        root.alignment = .leading
        root.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        root.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: container.topAnchor),
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            root.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            header.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -16),
            rowsStack.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -16),
            pager.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -16),
        ])
    }

    // MARK: data

    func setRows(_ rows: [MenuRow], threads: [BuildThread]) {
        threadsById = Dictionary(uniqueKeysWithValues: threads.map { ($0.id, $0) })
        model.setRows(rows)
        if model.isOpen { render() }
    }

    /// Usage page data. `nil` = the snapshot has no `usage` field yet.
    func setUsage(_ usage: [UsageRow]?, polledAt: String?) {
        hasUsageData = usage != nil
        usagePolledAt = polledAt
        model.setUsage(usage ?? [])
        if model.isOpen { render() }
    }

    /// Dev hook (`NAVI_OPEN_MENU=usage`): jump straight to the last page.
    func showUsagePage() {
        guard model.isOpen, !model.isUsagePage else { return }
        _ = model.turn(-1, land: .first)
        render()
    }

    // MARK: open / close

    /// Opens next to Navi (scene coords) on page 1, first row highlighted.
    func open(near scene: CGPoint, stage: CGRect, workingColor: String) {
        onSound?(model.open())
        self.workingColor = workingColor
        render()
        panel.layoutIfNeeded()
        let h = container.fittingSize.height
        let x = min(stage.maxX - MenuController.width - 8, max(stage.minX + 8, scene.x + 24))
        let y = min(stage.maxY - 60 - h, max(stage.minY + 8, scene.y - 60))
        panel.setFrame(NSRect(x: x, y: Screens.primaryHeight - (y + h), width: MenuController.width, height: h), display: true)
        panel.makeKeyAndOrderFront(nil)
        if ProcessInfo.processInfo.environment["NAVI_DEBUG"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                NSLog("menu isKey=%d isVisible=%d appActive=%d", self?.panel.isKeyWindow == true ? 1 : 0, self?.panel.isVisible == true ? 1 : 0, NSApp.isActive ? 1 : 0)
            }
        }
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close()
        }
    }

    func close(silent: Bool = false) {
        guard model.isOpen else { return }
        if let s = model.close(silent: silent) { onSound?(s) }
        if let m = outsideMonitor { NSEvent.removeMonitor(m); outsideMonitor = nil }
        panel.orderOut(nil)
        onClosed?()
    }

    // MARK: actions

    private var workingColor = "#fff8ad"

    private func toggleSort() {
        guard let s = model.toggleSort() else { return }
        onSound?(s)
        onSortChanged?(model.sort)
        render()
    }

    private func turn(_ delta: Int) {
        guard let s = model.turn(delta, land: .keep) else { return }
        onSound?(s)
        render()
    }

    private func move(_ delta: Int) {
        guard let s = model.move(delta) else { return }
        onSound?(s)
        render()
    }

    private func hoverRow(_ i: Int) {
        if let s = model.moveTo(i) { onSound?(s) }
        highlight()
    }

    private func select() {
        guard let (row, sound) = model.select() else { return }
        onSound?(sound)
        (rowViews[safe: model.idx] as? MenuRowView)?.flash = true
        let thread = threadsById[row.id]
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
            self?.close(silent: true)
            self?.onSelect?(row, thread)
        }
    }

    private func handleKey(_ e: NSEvent) -> Bool {
        guard model.isOpen else { return false }
        switch e.keyCode {
        case 125: move(1); return true          // ↓
        case 126: move(-1); return true         // ↑
        case 124: turn(1); return true          // →
        case 123: turn(-1); return true         // ←
        case 36, 76: select(); return true      // Return / Enter
        case 53: close(); return true           // Esc
        case 48: toggleSort(); return true      // Tab
        default: return false
        }
    }

    // MARK: render

    private var rowViews: [MenuSelectableView] = []

    private func render() {
        rowsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        rowViews = []
        if model.isUsagePage { renderUsageRows() } else { renderThreadRows() }
        for v in rowViews { v.widthAnchor.constraint(equalToConstant: MenuController.width - 16).isActive = true }
        title.stringValue = model.isUsagePage ? "quota usage · ↑↓ ←→ esc" : "build threads · ↑↓ ←→ ⇥ ⏎ esc"
        sortButton.title = "⇅ \(model.sort.rawValue)"
        sortButton.isHidden = model.isUsagePage
        if let p = model.pagerText {
            pager.isHidden = false
            pagerLabel.stringValue = p
            sortNote.stringValue = "· \(model.pageNote)"
        } else {
            pager.isHidden = true
        }
        highlight()
        panel.layoutIfNeeded()
        let h = container.fittingSize.height
        if panel.isVisible, abs(panel.frame.height - h) > 0.5 {
            let f = panel.frame
            panel.setFrame(NSRect(x: f.minX, y: f.maxY - h, width: f.width, height: h), display: true)
        }
    }

    private func renderThreadRows() {
        let rows = model.pageRows
        if rows.isEmpty {
            let empty = MenuRowView(row: MenuRow(id: "", name: "no build threads", state: .idle, changedAt: 0, status: ""), workingColor: workingColor, index: 0)
            empty.showDot = false
            rowsStack.addArrangedSubview(empty)
            rowViews = [empty]
        }
        for (i, r) in rows.enumerated() {
            let v = MenuRowView(row: r, workingColor: workingColor, index: i)
            v.onHover = { [weak self] i in self?.hoverRow(i) }
            v.onClick = { [weak self] i in
                guard let self else { return }
                _ = self.model.moveTo(i, quiet: true); self.highlight(); self.select()
            }
            v.onRightClick = { [weak self] i, event in self?.showActions(for: i, event: event) }
            rowsStack.addArrangedSubview(v)
            rowViews.append(v)
        }
    }

    /// One compact row per quota harness (label + one thin bar per window), then a dim footer
    /// with the no-quota harnesses. Enter on a row is a no-op; hover/↑↓ highlight like threads.
    private func renderUsageRows() {
        let rows = model.usageRows
        if !hasUsageData {
            rowsStack.addArrangedSubview(UsageNoteView(text: "collector has no usage data yet", height: 40))
        } else if rows.isEmpty {
            rowsStack.addArrangedSubview(UsageNoteView(text: "no harness reports a quota", height: 40))
        }
        for (i, r) in rows.enumerated() {
            let v = UsageRowView(row: r, index: i, now: Date())
            v.onHover = { [weak self] i in self?.hoverRow(i) }
            v.onClick = { [weak self] i in
                guard let self else { return }
                if let s = self.model.moveTo(i) { self.onSound?(s) }
                self.highlight()
            }
            rowsStack.addArrangedSubview(v)
            rowViews.append(v)
        }
        let footer = model.usageFooterRows
        if !footer.isEmpty {
            let f = UsageNoteView(text: "no quota: " + footer.map(\.footerText).joined(separator: ", "), height: 22)
            rowsStack.addArrangedSubview(f)
        }
        if let polled = usagePolledAt, hasUsageData {
            let ago = UsageFormat.parse(polled).map { Int(Date().timeIntervalSince($0)) } ?? 0
            let text = ago < 90 ? "polled just now" : (ago < 5400 ? "polled \(ago / 60)m ago" : "polled \(ago / 3600)h ago")
            rowsStack.addArrangedSubview(UsageNoteView(text: text, height: 18))
        }
        for v in rowsStack.arrangedSubviews where !(v is MenuSelectableView) {
            v.widthAnchor.constraint(equalToConstant: MenuController.width - 16).isActive = true
        }
    }

    private func highlight() {
        for (i, v) in rowViews.enumerated() { v.selected = i == model.idx && model.currentRowCount > 0 }
    }

    /// Right-click a row: every action the collector offers (destructive ones ask first).
    private func showActions(for i: Int, event: NSEvent) {
        guard let row = model.pageRows[safe: i], let thread = threadsById[row.id] else { return }
        let menu = NSMenu()
        let t = NSMenuItem(title: thread.branch ?? thread.name, action: nil, keyEquivalent: ""); t.isEnabled = false
        menu.addItem(t); menu.addItem(.separator())
        let actions = thread.actions ?? []
        if actions.isEmpty { let n = NSMenuItem(title: "No actions", action: nil, keyEquivalent: ""); n.isEnabled = false; menu.addItem(n) }
        for a in actions {
            let item = NSMenuItem(title: a.label, action: #selector(MenuActionTarget.run(_:)), keyEquivalent: "")
            item.target = MenuActionTarget.shared
            item.representedObject = MenuActionTarget.Payload(action: a, thread: thread) { [weak self] in self?.close(silent: true) }
            if a.isDestructive { item.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil) }
            menu.addItem(item)
        }
        if let v = rowViews[safe: i] { NSMenu.popUpContextMenu(menu, with: event, for: v) }
    }
}

/// Target for the row context menu (NSMenuItem needs an ObjC selector).
final class MenuActionTarget: NSObject {
    static let shared = MenuActionTarget()
    final class Payload: NSObject {
        let action: ThreadAction; let thread: BuildThread; let before: () -> Void
        init(action: ThreadAction, thread: BuildThread, before: @escaping () -> Void) { self.action = action; self.thread = thread; self.before = before }
    }
    @objc func run(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? Payload else { return }
        p.before()
        ActionRunner.run(p.action, for: p.thread)
    }
}

// MARK: - panel + views

enum MenuTheme {
    static let bg = NSColor(srgbRed: 0x1e / 255, green: 0x1e / 255, blue: 0x1e / 255, alpha: 1)
    static let bg3 = NSColor(srgbRed: 0x24 / 255, green: 0x24 / 255, blue: 0x24 / 255, alpha: 1)
    static let line = NSColor(srgbRed: 0x3a / 255, green: 0x3a / 255, blue: 0x3a / 255, alpha: 1)
    static let fg = NSColor(srgbRed: 0xed / 255, green: 0xe6 / 255, blue: 0xe6 / 255, alpha: 1)
    static let fg2 = NSColor(srgbRed: 0xa8 / 255, green: 0x9f / 255, blue: 0x9f / 255, alpha: 1)
    static let fg3 = NSColor(srgbRed: 0x6f / 255, green: 0x67 / 255, blue: 0x67 / 255, alpha: 1)
    static let accent = NSColor(srgbRed: 0xe1 / 255, green: 0x4d / 255, blue: 0x1a / 255, alpha: 1)

    static func color(_ hex: String) -> NSColor {
        let c = RGB(hex: hex)
        return NSColor(srgbRed: c.r / 255, green: c.g / 255, blue: c.b / 255, alpha: 1)
    }
}

/// Non-activating panel that can still become key so arrow keys reach it.
final class MenuPanel: NSPanel {
    var onKey: ((NSEvent) -> Bool)?
    var onResignKey: (() -> Void)?

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}

final class MenuContainerView: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        MenuTheme.bg.setFill(); path.fill()
        MenuTheme.line.setStroke(); path.lineWidth = 1; path.stroke()
    }
}

final class MenuTextButton: NSView {
    var title: String { didSet { label.stringValue = title; needsDisplay = true } }
    var onClick: (() -> Void)?
    private let label = NSTextField(labelWithString: "")
    private var hover = false

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
        label.stringValue = title
        label.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        label.textColor = MenuTheme.fg
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        (hover ? NSColor(white: 0x2b / 255, alpha: 1) : MenuTheme.bg3).setFill(); p.fill()
        (hover ? MenuTheme.fg3 : MenuTheme.line).setStroke(); p.stroke()
    }
    override func mouseEntered(with event: NSEvent) { hover = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hover = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() } }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class MenuRowView: MenuSelectableView {
    static let idleOpacity: CGFloat = 0.45
    let row: MenuRow
    let index: Int
    private let color: NSColor
    var flash = false { didSet { needsDisplay = true } }
    var showDot = true { didSet { needsDisplay = true } }
    var onHover: ((Int) -> Void)?
    var onClick: ((Int) -> Void)?
    var onRightClick: ((Int, NSEvent) -> Void)?

    init(row: MenuRow, workingColor: String, index: Int) {
        self.row = row; self.index = index
        self.color = MenuTheme.color(row.state.hex(workingColor: workingColor))
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: MenuController.rowHeight).isActive = true

        // Idle rows (collector: resting past its active window) are secondary: dimmed text,
        // dimmed dot, listed after the active rows. Still clickable.
        let dim: CGFloat = row.idle ? MenuRowView.idleOpacity : 1
        let name = NSTextField(labelWithString: row.name)
        name.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        name.textColor = MenuTheme.fg.withAlphaComponent(dim)
        name.lineBreakMode = .byTruncatingTail
        let status = NSTextField(labelWithString: row.status)
        status.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        status.textColor = MenuTheme.fg3.withAlphaComponent(dim)
        status.lineBreakMode = .byTruncatingTail
        let state = NSTextField(labelWithString: row.status.isEmpty && row.id.isEmpty ? "" : "\(row.state.symbol) \(row.idle ? "idle" : row.state.label)")
        state.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        state.textColor = MenuTheme.fg2.withAlphaComponent(dim)
        state.setContentCompressionResistancePriority(.required, for: .horizontal)
        for v in [name, status, state] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 26),
            name.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            name.trailingAnchor.constraint(lessThanOrEqualTo: state.leadingAnchor, constant: -10),
            status.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            status.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 1),
            status.trailingAnchor.constraint(lessThanOrEqualTo: state.leadingAnchor, constant: -10),
            state.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            state.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0, dy: 1)
        if flash {
            MenuTheme.accent.withAlphaComponent(0.35).setFill()
            NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8).fill()
        } else if selected {
            MenuTheme.bg3.setFill()
            NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8).fill()
            color.setStroke()
            let o = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8); o.lineWidth = 1; o.stroke()
        }
        if showDot {
            NSGraphicsContext.current?.saveGraphicsState()
            let dotColor = row.idle ? color.withAlphaComponent(MenuRowView.idleOpacity) : color
            let shadow = NSShadow(); shadow.shadowColor = row.idle ? .clear : color; shadow.shadowBlurRadius = 8; shadow.set()
            dotColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: 8, y: bounds.midY - 4, width: 8, height: 8)).fill()
            NSGraphicsContext.current?.restoreGraphicsState()
        }
    }

    override func mouseEntered(with event: NSEvent) { onHover?(index) }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?(index) } }
    override func rightMouseDown(with event: NSEvent) { onRightClick?(index, event) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Anything the cursor can land on (thread rows and usage rows).
class MenuSelectableView: NSView {
    var selected = false { didSet { needsDisplay = true } }
}

/// A dim one-line note (usage footer / empty states). Not selectable.
final class UsageNoteView: NSView {
    private let label = NSTextField(labelWithString: "")
    init(text: String, height: CGFloat) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: height).isActive = true
        label.stringValue = text
        label.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        label.textColor = MenuTheme.fg3
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// One harness on the usage page. Fully custom-drawn so 6+ rows stay compact:
///   Claude Code · Max 5x                                   !
///   5h        ▓▓▓▓░░░░░░  38%   resets in 2h 14m
///   7d        ▓░░░░░░░░░  12%   resets in 6d 11h
final class UsageRowView: MenuSelectableView {
    static let headerHeight: CGFloat = 20
    static let lineHeight: CGFloat = 14
    static let padTop: CGFloat = 5
    static let padBottom: CGFloat = 5

    let row: UsageRow
    let index: Int
    private let now: Date
    var onHover: ((Int) -> Void)?
    var onClick: ((Int) -> Void)?

    static func height(for row: UsageRow) -> CGFloat {
        padTop + headerHeight + CGFloat(row.detailLineCount) * lineHeight + padBottom
    }

    init(row: UsageRow, index: Int, now: Date) {
        self.row = row; self.index = index; self.now = now
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: UsageRowView.height(for: row)).isActive = true
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        toolTipText()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func toolTipText() {
        var parts: [String] = []
        if let reason = row.blockedReason { parts.append(reason) }
        if let shared = row.sharedBy, !shared.isEmpty { parts.append("shared by \(shared.joined(separator: ", "))") }
        if let note = row.note { parts.append(note) }
        toolTip = parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    override var isFlipped: Bool { true }

    private var accent: NSColor {
        if row.error != nil { return MenuTheme.fg3 }
        if row.blocked { return MenuTheme.color(UsageBar.red) }
        let worst = row.windows.map(\.usedPct).max() ?? 0
        return MenuTheme.color(UsageBar.hex(forPct: worst))
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0, dy: 1)
        let dim = row.error != nil
        if row.blocked && !dim {
            MenuTheme.color(UsageBar.red).withAlphaComponent(0.10).setFill()
            NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8).fill()
        }
        if selected {
            MenuTheme.bg3.setFill()
            NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8).fill()
            accent.setStroke()
            let o = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8); o.lineWidth = 1; o.stroke()
        }

        let x0: CGFloat = 12
        let right = bounds.width - 10
        var y = UsageRowView.padTop

        // header: label (+ plan is already folded into label by the collector)
        let labelColor: NSColor = dim ? MenuTheme.fg3 : (row.blocked ? MenuTheme.color(UsageBar.red) : MenuTheme.fg)
        let labelAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: labelColor]
        var labelRect = NSRect(x: x0, y: y + 2, width: right - x0, height: UsageRowView.headerHeight)
        if let err = row.error {
            let errAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular), .foregroundColor: MenuTheme.fg3]
            let ns = NSAttributedString(string: err, attributes: errAttrs)
            let w = min(ns.size().width, right - x0 - 120)
            ns.draw(with: NSRect(x: right - w, y: y + 4, width: w, height: UsageRowView.headerHeight), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            labelRect.size.width -= w + 8
        } else if row.blocked {
            let bang = NSAttributedString(string: "!", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .bold), .foregroundColor: MenuTheme.color(UsageBar.red)])
            bang.draw(at: NSPoint(x: right - bang.size().width, y: y + 2))
            labelRect.size.width -= 16
        }
        NSAttributedString(string: row.label, attributes: labelAttrs)
            .draw(with: labelRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        y += UsageRowView.headerHeight
        if dim { return }

        let mono: NSFont = .monospacedSystemFont(ofSize: 10, weight: .regular)
        let nameW: CGFloat = 92
        let barX = x0 + nameW + 6
        let barW: CGFloat = 64
        let pctX = barX + barW + 8
        let resetX = pctX + 38
        for w in row.windows {
            let nameAttrs: [NSAttributedString.Key: Any] = [.font: mono, .foregroundColor: MenuTheme.fg2]
            NSAttributedString(string: w.name, attributes: nameAttrs)
                .draw(with: NSRect(x: x0, y: y + 1, width: nameW, height: UsageRowView.lineHeight), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            // bar
            let track = NSRect(x: barX, y: y + 5, width: barW, height: 4)
            MenuTheme.line.setFill(); NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
            let fill = CGFloat(UsageBar.fill(forPct: w.usedPct))
            if fill > 0 {
                MenuTheme.color(UsageBar.hex(forPct: w.usedPct)).setFill()
                NSBezierPath(roundedRect: NSRect(x: barX, y: y + 5, width: max(3, barW * fill), height: 4), xRadius: 2, yRadius: 2).fill()
            }
            let pctAttrs: [NSAttributedString.Key: Any] = [.font: mono, .foregroundColor: w.usedPct >= 90 ? MenuTheme.color(UsageBar.red) : MenuTheme.fg]
            NSAttributedString(string: UsageFormat.pct(w.usedPct), attributes: pctAttrs).draw(at: NSPoint(x: pctX, y: y + 1))
            let until = UsageFormat.resetsIn(w.resetsAt, now: now)
            if !until.isEmpty {
                let ra: [NSAttributedString.Key: Any] = [.font: mono, .foregroundColor: MenuTheme.fg3]
                NSAttributedString(string: "resets in \(until)", attributes: ra)
                    .draw(with: NSRect(x: resetX, y: y + 1, width: right - resetX, height: UsageRowView.lineHeight), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            }
            y += UsageRowView.lineHeight
        }
        if let c = row.credits {
            let nameAttrs: [NSAttributedString.Key: Any] = [.font: mono, .foregroundColor: MenuTheme.fg2]
            NSAttributedString(string: "credits", attributes: nameAttrs).draw(at: NSPoint(x: x0, y: y + 1))
            var text = c.text
            let until = UsageFormat.resetsIn(c.resetsAt, now: now)
            if !until.isEmpty { text += " · resets in \(until)" }
            NSAttributedString(string: text, attributes: [.font: mono, .foregroundColor: MenuTheme.fg])
                .draw(with: NSRect(x: barX, y: y + 1, width: right - barX, height: UsageRowView.lineHeight), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            y += UsageRowView.lineHeight
        }
    }

    override func mouseEntered(with event: NSEvent) { onHover?(index) }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?(index) } }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

extension Array {
    subscript(safe i: Int) -> Element? { i >= 0 && i < count ? self[i] : nil }
}
