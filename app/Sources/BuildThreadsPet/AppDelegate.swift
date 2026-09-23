import AppKit
import Carbon.HIToolbox
import QuartzCore
import ServiceManagement
import PetCore

/// Glue: collector snapshot → Navi states → color engine / symbol pops / sleep / menu rows,
/// plus the 60 fps tick that moves the panel, the menubar Triforce (left-click hide/show,
/// right-click menu) and the ⌥⌘P / ⌥⌘N hotkeys.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let scene = NaviScene()
    private var panel: PetPanel!
    private var view: NaviView!
    private var menu: MenuController!
    private var sound: SoundPlayer!
    private var statusItem: NSStatusItem!
    private var statusMenu: NSMenu!
    private var hotKey: HotKey?
    private var hideHotKey: HotKey?
    private var link: CADisplayLink?
    private let store = ThreadsStore(url: Paths.threadsJSON)

    private var config = Prefs.config
    private var engine = ColorEngine()
    private var transitions = TransitionDetector()
    private var sleepTimer: SleepTimer!
    private var gate = SfxGate()
    private var visibility = Prefs.visibility
    private var changedAt = Prefs.changedAt
    private var liveStates: [NaviState] = []
    private var threads: [BuildThread] = []
    private var lastTick = 0.0
    /// Collector liveness (CollectorHealth.staleAfter). Re-checked on every snapshot and on a
    /// timer, because a file that stops changing never triggers the store's onChange.
    private var health: CollectorHealth = .missing
    private var healthTimer: Timer?
    private let idleNotifier = IdleNotifier()

    private var now: Double { CACurrentMediaTime() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        sleepTimer = SleepTimer(threshold: config.params.sleepMin * 60, now: now)
        applyConfig()

        view = NaviView(scene: scene)
        panel = PetPanel()
        panel.contentView = view
        sound = SoundPlayer()
        menu = MenuController(sort: config.menuSort)
        menu.onSound = { [weak self] id in self?.sfx(id) }
        menu.onSelect = { [weak self] row, thread in self?.runPrimary(row: row, thread: thread) }
        menu.onSortChanged = { [weak self] s in
            guard let self else { return }
            self.config.menuSort = s; Prefs.config = self.config
        }

        placeInitially()
        view.onClick = { [weak self] in self?.naviClicked() }
        view.onRightClick = { [weak self] e in self?.showNaviMenu(e) }
        view.onDropped = { [weak self] in
            guard let self else { return }
            Prefs.home = NSPoint(x: self.scene.home.x, y: self.scene.home.y)
            self.menu.close()
        }

        setUpStatusItem()
        hotKey = HotKey(id: 1, keyCode: UInt32(kVK_ANSI_P)) { [weak self] in self?.toggleSleep() }
        hideHotKey = HotKey(id: 2, keyCode: UInt32(kVK_ANSI_N)) { [weak self] in self?.toggleHidden() }

        store.onChange = { [weak self] snap in self?.snapshotChanged(snap) }
        store.start()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.recheckHealth() }
        healthTimer?.tolerance = 3
        if Prefs.sleeping { sleepTimer.sleep(now: now) }
        NSLog("Navi: launched pid %d, threads.json at %@", ProcessInfo.processInfo.processIdentifier, Paths.threadsJSON.path)

        if Prefs.idleNotifications { idleNotifier.prepare() }
        gate.hidden = visibility.hidden
        if !visibility.hidden { panel.orderFrontRegardless() }   // hidden last time → stays hidden
        refreshStatusIcon()
        link = view.displayLink(target: self, selector: #selector(tick))
        link?.add(to: .main, forMode: .common)

        // Dev hook for screenshots: NAVI_OPEN_MENU=1 opens the menu right away;
        // NAVI_OPEN_MENU=usage opens it on the last (quota usage) page.
        let openMenuEnv = ProcessInfo.processInfo.environment["NAVI_OPEN_MENU"]
        if openMenuEnv == "1" || openMenuEnv == "usage" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.openMenu()
                if openMenuEnv == "usage" { self?.menu.showUsagePage() }
            }
        }
        // Dev hook for docs: NAVI_MENUBAR_SHOT=<dir> captures the menubar Triforce shown and
        // hidden (menubar-shown.png / menubar-hidden.png), then restores and quits.
        if let dir = ProcessInfo.processInfo.environment["NAVI_MENUBAR_SHOT"], !dir.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.captureMenubar(to: dir) }
        }
    }

    /// `screencapture -R` wants top-left screen points; the button's window frame is Cocoa
    /// (bottom-left). Pads 6 pt each side so the glyph is not clipped at the item's edge.
    private func captureMenubar(to dir: String) {
        guard let win = statusItem.button?.window else { return }
        let f = win.frame.insetBy(dx: -6, dy: 0)
        let top = Screens.primaryHeight - f.maxY
        let region = "\(Int(f.minX)),\(Int(top)),\(Int(f.width)),\(Int(f.height))"
        let shot: (String) -> Void = { name in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", "-R", region, "\(dir)/\(name).png"]
            try? p.run(); p.waitUntilExit()
        }
        let wasHidden = visibility.hidden
        showNavi()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            shot("menubar-shown")
            self?.hideNavi()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                shot("menubar-hidden")
                if !wasHidden { self?.showNavi() }
                NSApp.terminate(nil)
            }
        }
    }

    /// Navi must never exit on her own. The only legitimate paths are the Quit menu items
    /// (`quit()`, which sets `quitRequested`) and a kill from outside. Anything else that
    /// lands here is a bug — say so in the log so the next "she quit by herself" has a trail.
    private var quitRequested = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        NSLog("Navi: applicationShouldTerminate — %@", quitRequested ? "Quit chosen from the menu" : "NOT requested from Navi's menu (external terminate / logout / AppleEvent)")
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSLog("Navi: terminating (%@)", quitRequested ? "menu Quit" : "external")
        store.stop()
        healthTimer?.invalidate(); healthTimer = nil
        link?.invalidate()
    }

    private func applyConfig() {
        scene.params = config.params
        scene.mode = config.mode == "follow" ? "follow" : "hover"
        engine.workingColor = config.params.coreColor
        sleepTimer?.threshold = config.params.sleepMin * 60
        gate.enabled = config.params.sound
    }

    private func placeInitially() {
        let stage = Screens.stage(containing: Screens.mouseScene)
        var home = Prefs.home.map { NaviScene.Point(x: $0.x, y: $0.y) }
            ?? NaviScene.Point(x: stage.maxX - 140, y: stage.maxY - 160)
        // saved spot off every screen (monitor unplugged) → default
        let homeCocoa = Screens.toCocoa(NSPoint(x: home.x, y: home.y))
        if !NSScreen.screens.contains(where: { $0.frame.insetBy(dx: -40, dy: -40).contains(homeCocoa) }) {
            home = NaviScene.Point(x: stage.maxX - 140, y: stage.maxY - 160)
        }
        scene.home = home
        scene.x = home.x; scene.y = home.y; scene.rx = home.x; scene.ry = home.y
        scene.stage = Screens.stage(containing: NSPoint(x: home.x, y: home.y))
    }

    // MARK: collector → states

    /// Timer path: nothing changed on disk, but the snapshot may have aged past the guard
    /// (or a restarted collector may have made it fresh again — that arrives via onChange).
    private func recheckHealth() {
        let h = CollectorHealth.check(snapshot: store.snapshot, fileExists: store.fileExists)
        guard h.isLive != health.isLive else { return }
        NSLog("Navi: collector %@", h.summary ?? "fresh again")
        snapshotChanged(store.snapshot)
    }

    private func snapshotChanged(_ snap: ThreadsSnapshot?) {
        let t = now
        let wall = Date().timeIntervalSince1970
        health = CollectorHealth.check(snapshot: snap, fileExists: store.fileExists)
        // Stale / missing: everything in the file is history. No threads, no live states —
        // never present a dead collector's sessions as live.
        threads = health.isLive ? (snap?.threads ?? []) : []
        let states = threads.map { ($0.id, NaviStateMapper.state(for: $0)) }
        let changes = transitions.observe(states.map { (id: $0.0, state: $0.1) })
        for c in changes { changedAt[c.id] = wall }
        // first-seen threads: fall back to the last commit time so "recent" has an order on launch
        for th in threads where changedAt[th.id] == nil {
            changedAt[th.id] = th.git?.lastCommitAt.flatMap { ISO8601DateFormatter.lenientDate($0)?.timeIntervalSince1970 } ?? 0
        }
        changedAt = changedAt.filter { key, _ in threads.contains { $0.id == key } }
        Prefs.changedAt = changedAt

        liveStates = NaviStateMapper.liveSet(states.map(\.1))
        engine.setLive(health.isLive ? liveStates : [])

        if !changes.isEmpty {
            if sleepTimer.noteChange(now: t) { Prefs.sleeping = false }
            if let pop = TransitionDetector.popState(for: changes) { popSym(pop) }
            // working → idle = the parent agent finished its turn: your cue.
            if Prefs.idleNotifications {
                for alert in IdleAlert.alerts(for: changes, threads: threads) { idleNotifier.post(alert) }
            }
        }
        refreshMenuRows()
        // Usage is menu-only: it never touches Navi's color, pops, or sleep.
        menu.setUsage(snap?.usage, polledAt: snap?.usagePolledAt)
        refreshStatusIcon()
    }

    private func refreshMenuRows() {
        var rows: [MenuRow]
        if let down = health.menuRow {
            rows = [down]
        } else {
            rows = threads.map { th in
                var status = th.stateLabel ?? th.state.rawValue
                if let d = th.detail, !d.isEmpty { status += " · \(d)" }
                // "recent" = newest of (last Navi-state change, last session activity)
                let recency = max(changedAt[th.id] ?? 0, th.lastSeenEpoch ?? 0)
                return MenuRow(id: th.id, name: th.name, state: NaviStateMapper.state(for: th),
                               changedAt: recency, status: status, idle: th.idle ?? false)
            }
        }
        menu.setRows(rows, threads: threads)
    }

    // MARK: tick

    @objc private func tick() {
        let t = now
        let dt = lastTick == 0 ? 1.0 / 60 : min(0.05, t - lastTick)
        lastTick = t

        if sleepTimer.tick(now: t) {                         // dozed off
            Prefs.sleeping = true
            popSym(.sleep)
            menu.close(silent: true)
        }
        engine.sleeping = sleepTimer.sleeping
        engine.update(dt: dt)
        scene.rgb = engine.rgb
        scene.sleeping = sleepTimer.sleeping
        scene.mouse = NaviScene.Point(x: Screens.mouseScene.x, y: Screens.mouseScene.y)
        scene.stage = Screens.stage(containing: NSPoint(x: scene.x, y: scene.y))
        if let b = scene.bubble, b.alpha(now: t) == nil { scene.bubble = nil }
        scene.step(t: t)

        // Hidden: the scene keeps stepping (state stays current) but the panel is ordered out,
        // so there is nothing to move or redraw.
        guard !visibility.hidden else { return }
        let origin = Screens.toCocoa(NSPoint(x: scene.rx - PetPanel.size.width / 2, y: scene.ry + PetPanel.size.height / 2))
        panel.setFrameOrigin(origin)
        let interactive = scene.hover || scene.dragging
        if panel.ignoresMouseEvents == interactive { panel.ignoresMouseEvents = !interactive }
        view.needsDisplay = true
    }

    // MARK: pops, sleep, wake

    private func popSym(_ state: NaviState) {
        guard let state = visibility.pop(state) else { return }   // hidden: no pop, no sound, no auto-show
        let rgb = RGB(hex: state.hex(workingColor: config.params.coreColor))
        scene.bubble = SymbolBubble(state: state, rgb: rgb, at: now)
        scene.burst(state == .sleep ? 8 : 16, NaviScene.EmitOpts(speed: state == .sleep ? 30 : 100, life: 0.7, rgb: rgb))
        if state == .blocked { scene.shake = 0.4 }
        sfx(.naviIn)                                          // the one notification sound, rate-limited in the gate
    }

    private func sfx(_ id: SoundID) {
        guard gate.request(id, now: now) else { return }
        sound.play(id)
    }

    func toggleSleep() { sleepTimer.sleeping ? wake(fromClick: true) : sleep() }

    func sleep() {
        guard !sleepTimer.sleeping else { return }
        sleepTimer.sleep(now: now)
        Prefs.sleeping = true
        popSym(.sleep)
        menu.close(silent: true)
        refreshStatusIcon()
    }

    func wake(fromClick: Bool) {
        guard sleepTimer.wake(now: now) else { return }
        Prefs.sleeping = false
        if fromClick {
            popSym(liveStates.first ?? .idle)
            scene.burst(24, NaviScene.EmitOpts(speed: 120, life: 0.8))
        }
        refreshStatusIcon()
    }

    // MARK: hide / show (menubar Triforce, ⌥⌘N). Not sleep — see NaviVisibility.

    func toggleHidden() { visibility.hidden ? showNavi() : hideNavi() }

    func hideNavi() {
        guard visibility.hide() else { return }
        Prefs.visibility = visibility
        gate.hidden = true
        menu.close(silent: true)
        panel.orderOut(nil)
        refreshStatusIcon()
    }

    /// Back at her last position (the scene kept moving while hidden), with the navi-in chime.
    func showNavi() {
        guard visibility.show() else { return }
        Prefs.visibility = visibility
        gate.hidden = false
        panel.setFrameOrigin(Screens.toCocoa(NSPoint(x: scene.rx - PetPanel.size.width / 2, y: scene.ry + PetPanel.size.height / 2)))
        panel.orderFrontRegardless()
        view.needsDisplay = true
        sfx(NaviVisibility.showSound)
        refreshStatusIcon()
    }

    // MARK: menu

    private func naviClicked() {
        if sleepTimer.sleeping { wake(fromClick: true) }
        if menu.isOpen { menu.close() } else { openMenu() }
    }

    private func openMenu() {
        refreshMenuRows()
        menu.open(near: CGPoint(x: scene.rx, y: scene.ry), stage: scene.stage, workingColor: config.params.coreColor)
    }

    private func runPrimary(row: MenuRow, thread: BuildThread?) {
        if row.id == CollectorHealth.rowId {
            NSWorkspace.shared.activateFileViewerSelecting([Paths.threadsJSON.deletingLastPathComponent()])
            return
        }
        guard let thread, let action = thread.primaryAction(openChatsInBrowser: Prefs.openChatsInBrowser) else { return }
        ActionRunner.run(action, for: thread)
    }

    // MARK: menus

    private func showNaviMenu(_ event: NSEvent) {
        menu.close(silent: true)
        let m = NSMenu()
        m.addItem(withTitle: "Hide Navi  ⌥⌘N", action: #selector(menuToggleHidden), keyEquivalent: "").target = self
        m.addItem(withTitle: sleepTimer.sleeping ? "Wake Navi  ⌥⌘P" : "Sleep Navi  ⌥⌘P", action: #selector(menuToggleSleep), keyEquivalent: "").target = self
        let snd = NSMenuItem(title: "Sound", action: #selector(toggleSound), keyEquivalent: "")
        snd.target = self; snd.state = config.params.sound ? .on : .off
        m.addItem(snd)
        m.addItem(idleNotifyItem())
        m.addItem(withTitle: "Open threads.json", action: #selector(openThreadsJSON), keyEquivalent: "").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "").target = self
        NSMenu.popUpContextMenu(m, with: event, for: view)
    }

    /// Left-click = hide/show, right-click (or ctrl-click) = the menu. `statusItem.menu` is
    /// only assigned for the duration of the right-click; left permanently set, AppKit would
    /// open the menu on every click and the button action would never fire.
    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusMenu = NSMenu()
        statusMenu.delegate = self
        if let b = statusItem.button {
            b.target = self
            b.action = #selector(statusItemClicked)
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        refreshStatusIcon()
    }

    @objc private func statusItemClicked() {
        let e = NSApp.currentEvent
        let rightish = e?.type == .rightMouseUp || (e?.modifierFlags.contains(.control) ?? false)
        if rightish {
            statusItem.menu = statusMenu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            toggleHidden()
        }
    }

    func menuNeedsUpdate(_ m: NSMenu) {
        m.removeAllItems()
        let hide = NSMenuItem(title: visibility.hidden ? "Show Navi" : "Hide Navi", action: #selector(menuToggleHidden), keyEquivalent: "n")
        hide.keyEquivalentModifierMask = [.command, .option]
        hide.target = self
        m.addItem(hide)
        let toggle = NSMenuItem(title: sleepTimer.sleeping ? "Wake Navi" : "Sleep Navi", action: #selector(menuToggleSleep), keyEquivalent: "p")
        toggle.keyEquivalentModifierMask = [.command, .option]
        toggle.target = self
        m.addItem(toggle)
        let status = NSMenuItem(title: statusSummary(), action: nil, keyEquivalent: ""); status.isEnabled = false
        m.addItem(status)
        m.addItem(.separator())
        let snd = NSMenuItem(title: "Sound", action: #selector(toggleSound), keyEquivalent: "")
        snd.target = self; snd.state = config.params.sound ? .on : .off
        m.addItem(snd)
        m.addItem(idleNotifyItem())
        if !sound.missing.isEmpty {
            let miss = NSMenuItem(title: "\(sound.missing.count) sound\(sound.missing.count == 1 ? "" : "s") not installed → silent", action: nil, keyEquivalent: "")
            miss.toolTip = "Drop your own files in the sfx folder (README → Sounds), then relaunch Navi."
            miss.isEnabled = false
            m.addItem(miss)
        }
        m.addItem(.separator())
        m.addItem(withTitle: "Paste Navi config from clipboard", action: #selector(pasteConfig), keyEquivalent: "").target = self
        m.addItem(withTitle: "Copy Navi config", action: #selector(copyConfig), keyEquivalent: "").target = self
        m.addItem(withTitle: "Reset Navi config", action: #selector(resetConfig), keyEquivalent: "").target = self
        m.addItem(.separator())
        let browser = NSMenuItem(title: "Open chats in browser", action: #selector(toggleOpenChatsInBrowser), keyEquivalent: "")
        browser.target = self; browser.state = Prefs.openChatsInBrowser ? .on : .off
        browser.toolTip = "Off: a click on a chat row opens it in the Omnigent desktop app (omnigent://). On: the web UI."
        m.addItem(browser)
        m.addItem(.separator())
        m.addItem(withTitle: "Open threads.json", action: #selector(openThreadsJSON), keyEquivalent: "").target = self
        m.addItem(withTitle: "Open sfx folder", action: #selector(openSfxFolder), keyEquivalent: "").target = self
        m.addItem(.separator())
        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        if Bundle.main.bundleURL.pathExtension != "app" {
            login.isEnabled = false
            login.toolTip = "Only available from the installed .app (run install.sh)"
        }
        m.addItem(login)
        m.addItem(.separator())
        m.addItem(withTitle: "Quit Navi", action: #selector(quit), keyEquivalent: "q").target = self
    }

    private func statusSummary() -> String {
        if let down = health.summary { return down }
        let n = threads.count
        var parts = ["\(n) thread\(n == 1 ? "" : "s")"]
        let states = threads.map { NaviStateMapper.state(for: $0) }
        for s in NaviState.liveOrder {
            let c = states.filter { $0 == s }.count
            if c > 0 { parts.append("\(c) \(s.label)") }
        }
        if parts.count == 1 { parts.append(n == 0 ? "none open" : "all idle") }
        if sleepTimer.sleeping { parts.append("sleeping") }
        return parts.joined(separator: " · ")
    }

    private func refreshStatusIcon() {
        guard let button = statusItem?.button else { return }
        button.image = TriforceIcon.image(MenubarIconSpec(live: liveStates, hidden: visibility.hidden))
        button.toolTip = visibility.tooltip(statusSummary())
    }

    // MARK: actions

    @objc private func menuToggleSleep() { toggleSleep() }
    @objc private func menuToggleHidden() { toggleHidden() }
    @objc private func quit() { quitRequested = true; NSApp.terminate(nil) }

    @objc private func toggleOpenChatsInBrowser() { Prefs.openChatsInBrowser.toggle() }

    private func idleNotifyItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Notify when an agent goes idle", action: #selector(toggleIdleNotifications), keyEquivalent: "")
        item.target = self
        item.state = Prefs.idleNotifications ? .on : .off
        item.toolTip = "macOS notification when a thread's parent agent finishes its turn (\"<name> is waiting on you\")."
        return item
    }

    @objc private func toggleIdleNotifications() {
        Prefs.idleNotifications.toggle()
        if Prefs.idleNotifications { idleNotifier.prepare() }
    }

    @objc private func toggleSound() {
        config.params.sound.toggle()
        Prefs.config = config
        applyConfig()
    }

    @objc private func pasteConfig() {
        guard let s = NSPasteboard.general.string(forType: .string) else { NSSound.beep(); return }
        do {
            let c = try NaviConfig.decode(Data(s.utf8))
            config = c
            Prefs.config = c
            applyConfig()
            scene.burst(16, NaviScene.EmitOpts(speed: 80, life: 0.6))
        } catch {
            NSLog("Navi: config paste rejected: \(error)")
            NSSound.beep()
        }
    }

    @objc private func copyConfig() {
        guard let data = try? config.encode() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(String(decoding: data, as: UTF8.self), forType: .string)
    }

    @objc private func resetConfig() {
        config = NaviConfig()
        Prefs.config = config
        applyConfig()
    }

    @objc private func openThreadsJSON() {
        if store.fileExists { NSWorkspace.shared.open(Paths.threadsJSON) }
        else { NSWorkspace.shared.activateFileViewerSelecting([Paths.threadsJSON.deletingLastPathComponent()]) }
    }

    @objc private func openSfxFolder() {
        try? FileManager.default.createDirectory(at: Paths.sfxDir, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([Paths.sfxDir])
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            NSLog("Navi: launch-at-login toggle failed \(error)")
        }
    }
}

extension ISO8601DateFormatter {
    static func lenientDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
