import AppKit
import Carbon.HIToolbox
import PetCore

/// Typing sounds + typing speed: owns the settings, the key listener, the click player and the
/// WPM meter, and draws its items in the menubar dropdown. OFF by default; while off nothing
/// listens, no engine exists, and no permission is asked for.
final class KeySoundController: NSObject {
    private let defaults = UserDefaults.standard
    private(set) var settings: KeySoundSettings
    private var meter: TypingMeter
    private let listener = KeyListener()
    private var player: KeySoundPlayer?
    /// Held keys whose press clicked, so each release pairs with one press (memory only).
    private var pairing = KeyPairing()
    /// Modifiers, caps lock and media keys → one physical press / release each (memory only).
    private var router = KeyStrokeRouter()
    /// The profile preview's own press/release pair, so its release obeys the same rules.
    private var previewPairing = KeyPairing()
    private weak var noteItem: NSMenuItem?
    /// *Quiet on calls*: runs only while the feature and that setting are both on.
    private let mic = MicMonitor()
    private var packs: [SoundPack] = [SoundPack.synth]
    /// The ★ as decoding found it, per pack loaded this run, keyed to its files' fingerprint.
    private var stars = DecodedStars()
    /// The files of the pack last sent to the player: a change reloads it.
    private var requestedFingerprint: PackFingerprint?
    /// An `expire` is queued for the router's recent reports.
    private var expiryQueued = false
    private var retryTimer: Timer?
    private var saveTimer: Timer?
    private var liveTimer: Timer?
    private weak var wpmItem: NSMenuItem?

    /// Master Sound toggle (`config.params.sound`) and hidden state, read on every press. Neither
    /// mutes clicks (`KeySoundGate`): the Typing sounds toggle alone does.
    var soundOn: () -> Bool = { true }
    var hidden: () -> Bool = { false }

    override init() {
        settings = KeySoundSettings(store: UserDefaults.standard)
        let today = TypingStats.dayKey(Date())
        meter = TypingMeter(stats: TypingStats.load(from: UserDefaults.standard, today: today) ?? TypingStats(day: today))
        super.init()
        listener.onKeyDown = { [weak self] code, isRepeat, flags, time in
            self?.keyDown(code: code, isRepeat: isRepeat, flags: flags, time: time)
        }
        listener.onKeyUp = { [weak self] code, time in
            guard let self else { return }
            self.route(self.router.keyUp(code, now: time), typed: true)
        }
        listener.onFlagsChanged = { [weak self] code, flags, time in
            guard let self else { return }
            // A modifier or caps lock on its own clicks too; it never counts as typing.
            self.route(self.router.flagsChanged(keyCode: code, flags: flags, now: time), typed: false)
        }
        listener.onSystemDefined = { [weak self] subtype, data1, time in
            guard let self else { return }
            self.route(self.router.mediaKey(subtype: subtype, data1: data1, now: time), typed: false)
        }
        // Key-ups may have been lost while the tap was down: forget held keys, so only a fresh
        // key-down can release.
        listener.onTapReset = { [weak self] in self?.pairing.reset(); self?.router.reset() }
        mic.onChange = { [weak self] inUse in
            NSLog(inUse ? "Navi: typing sounds quiet (a microphone is in use)" : "Navi: typing sounds back (microphone free)")
            self?.refreshNote()
        }
        if settings.enabled { start(prompt: false) }
    }

    private var listenerState: TypingMenu.Listener {
        guard settings.enabled else { return .off }
        return listener.isRunning ? .running : .needsPermission
    }

    // MARK: key presses (main run loop)

    /// The key code is used here in memory only (sound + pan lookup, press/release pairing) and
    /// goes nowhere else; the meter gets the press time.
    private func keyDown(code: UInt16, isRepeat: Bool, flags: UInt64, time: TimeInterval) {
        // Shortcut keys (the C of ⌘C) click like any key; only the WPM meter skips them.
        route(router.keyDown(code, isRepeat: isRepeat, flags: flags, now: time), typed: true)
        let command = flags & CGEventFlags.maskCommand.rawValue != 0, control = flags & CGEventFlags.maskControl.rawValue != 0
        guard let press = KeyEventFilter.press(keyCode: code, isRepeat: isRepeat, command: command, control: control) else { return }
        if press.countsAsTyping { meter.record(at: ProcessInfo.processInfo.systemUptime, day: TypingStats.dayKey(Date())) }
    }

    /// Plays the router's strokes, and does the two things every source shares: caps lock
    /// reports no key-up, so every caps press (however it came) gets its release
    /// `capsReleaseDelay` later; and the router's recent reports are dropped once the duplicate
    /// window has passed, so no key timing outlives it.
    private func route(_ strokes: [KeyStroke], typed: Bool) {
        for s in strokes {
            stroke(s, typed: typed)
            guard s == .down(KeyTap.capsLock), let generation = router.generation(of: KeyTap.capsLock) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + KeyStrokeRouter.capsReleaseDelay) { [weak self] in
                guard let self else { return }
                self.route(self.router.releaseCaps(generation: generation, now: ProcessInfo.processInfo.systemUptime), typed: false)
            }
        }
        if router.pendingReports > 0 && !expiryQueued {
            expiryQueued = true
            DispatchQueue.main.asyncAfter(deadline: .now() + KeyStrokeRouter.duplicateWindow + 0.01) { [weak self] in
                guard let self else { return }
                self.expiryQueued = false
                self.router.expire(now: ProcessInfo.processInfo.systemUptime)
                if self.router.pendingReports > 0 { self.route([], typed: false) }   // newer reports: queue again
            }
        }
    }

    /// One physical key down or up. A press is marked sounded only once the player really
    /// scheduled it; a release plays only for a press that clicked, and only if clicks are still
    /// allowed. Every up (and `.lost`) clears the key's pairing whatever happens next, so nothing
    /// stays held. Nothing plays while a password field has secure input on: macOS already
    /// withholds key events then (`typed` presses skip the check), but not flag changes or media
    /// keys, and a release (caps lock's delayed one too) may land after secure input came on.
    private func stroke(_ s: KeyStroke, typed: Bool) {
        switch s {
        case .down(let code):
            if pairing.keyDown(code, isRepeat: false), gateOpen, typed || !IsSecureEventInputEnabled(), let player, player.press(code) {
                pairing.pressSounded(code, generation: player.generation)
            }
        case .up(let code):
            guard let player else { pairing.reset(); return }
            if pairing.keyUp(code, generation: player.generation), gateOpen, !IsSecureEventInputEnabled() { player.release(code) }
        case .lost(let code):
            _ = pairing.keyUp(code, generation: player?.generation ?? 0)   // forget it, no sound
        }
    }

    private var gateOpen: Bool {
        KeySoundGate.shouldPlay(enabled: settings.enabled, soundOn: soundOn(), hidden: hidden(),
                                quietOnCalls: settings.quietOnCalls, micInUse: mic.inUse)
    }

    private func syncMicMonitor() {
        settings.enabled && settings.quietOnCalls ? mic.start() : mic.stop()
    }

    // MARK: on / off

    private func start(prompt: Bool) {
        if player == nil {
            player = KeySoundPlayer()
            player?.volume = settings.volume
            reloadPacks(force: true)
        }
        syncMicMonitor()
        if !listener.start() {
            if prompt { KeyListener.requestAccess() }
            NSLog("Navi: typing sounds waiting for Input Monitoring permission")
            // Granting in System Settings does not notify the app: retry until the tap comes up.
            if retryTimer == nil {
                let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
                    guard let self, self.listener.start() else { return }
                    self.retryTimer?.invalidate(); self.retryTimer = nil
                }
                t.tolerance = 1
                RunLoop.main.add(t, forMode: .common)
                retryTimer = t
            }
        }
        if saveTimer == nil {
            let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.flush() }
            t.tolerance = 10
            RunLoop.main.add(t, forMode: .common)
            saveTimer = t
        }
    }

    private func stop() {
        listener.stop()
        mic.stop()
        pairing.reset()
        router.reset()
        previewPairing.reset()
        retryTimer?.invalidate(); retryTimer = nil
        saveTimer?.invalidate(); saveTimer = nil
        player?.pause()
        player = nil
        flush()
    }

    /// Saves today's counts if they changed. Called every 30 s while on, and at quit.
    func flush() {
        guard meter.dirty else { return }
        meter.stats.save(to: defaults)
        meter.dirty = false
    }

    /// Rescans the packs folder (cheap: a handful of folders) so a fresh fetch shows up without a
    /// relaunch; asks the player for a new pack only when the profile it should play changed.
    /// Decoding happens off the main thread; `done` runs once the new pack is live.
    private func reloadPacks(force: Bool = false, done: (() -> Void)? = nil) {
        packs = SoundPackLibrary.scan(Paths.keySoundsDir)
        stars.apply(to: &packs) { PackFingerprint.of($0) }
        let pack = SoundPackLibrary.resolve(settings.profile, in: packs)
        // Same pack, same files: nothing to do. Recordings re-fetched or replaced under the same
        // names change the fingerprint, so the player decodes them again.
        let fingerprint = PackFingerprint.of(pack)
        guard let player, force || player.requestedID != pack.id || fingerprint != requestedFingerprint else { done?(); return }
        requestedFingerprint = fingerprint
        player.load(pack) { [weak self] id, everyKey in
            // A pack that did not decode at all went live as the synth click: no star either.
            if let self, pack.tier != .builtin, let ok = id == pack.id ? everyKey : false {
                self.stars.record(pack.id, fingerprint: fingerprint, everyKey: ok)
                self.stars.apply(to: &self.packs) { PackFingerprint.of($0) }
            }
            done?()
        }
    }

    // MARK: dropdown

    /// The typing items for the menubar dropdown's Settings section.
    func menuItems() -> [NSMenuItem] {
        reloadPacks()
        var items: [NSMenuItem] = []
        let toggle = NSMenuItem(title: TypingMenu.toggleTitle, action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.target = self
        toggle.state = settings.enabled ? .on : .off
        toggle.toolTip = TypingMenu.toggleTooltip
        items.append(toggle)

        for row in TypingMenu.rows(enabled: settings.enabled, listener: listenerState, secureInput: IsSecureEventInputEnabled(),
                                   callMuted: settings.quietOnCalls && mic.inUse) {
            switch row {
            case .stats:
                let wpm = NSMenuItem(title: wpmText(), action: nil, keyEquivalent: "")
                wpm.attributedTitle = wpmAttributed(wpmText())
                items.append(wpm)
                wpmItem = wpm
                // The status note always has an item (hidden when there is nothing to say), so
                // an open dropdown can show or clear "quiet · a microphone is in use" live.
                let m = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                m.isEnabled = false
                items.append(m)
                noteItem = m
                refreshNote()
            case .note:
                break   // drawn by the always-present note item above
            case .openSettings:
                let open = NSMenuItem(title: "    " + TypingMenu.openSettings, action: #selector(openInputMonitoring), keyEquivalent: "")
                open.target = self
                open.toolTip = "Turn on Navi under Privacy & Security → Input Monitoring. Navi retries every 2 s."
                items.append(open)
            }
        }

        let current = SoundPackLibrary.resolve(settings.profile, in: packs)
        let sub = NSMenu(); sub.autoenablesItems = false
        for p in packs {
            let m = NSMenuItem(title: p.menuTitle, action: #selector(pickProfile(_:)), keyEquivalent: "")
            m.target = self
            m.representedObject = p.id
            m.state = p.id == current.id ? .on : .off
            m.toolTip = p.tooltip
            sub.addItem(m)
        }
        if let hint = TypingMenu.everyKeyHint(packs) {
            let m = NSMenuItem(title: hint, action: nil, keyEquivalent: ""); m.isEnabled = false
            sub.addItem(m)
        }
        if let missing = TypingMenu.missingPacksNote(packs) {
            let m = NSMenuItem(title: missing, action: nil, keyEquivalent: ""); m.isEnabled = false
            sub.addItem(m)
        }
        sub.addItem(.separator())
        let volTitle = NSMenuItem(title: TypingMenu.volumeTitle(settings.volume), action: nil, keyEquivalent: ""); volTitle.isEnabled = false
        sub.addItem(volTitle)
        let slider = NSSlider(value: settings.volume, minValue: 0, maxValue: 1, target: self, action: #selector(volumeChanged(_:)))
        slider.isContinuous = false
        slider.frame = NSRect(x: 18, y: 4, width: 180, height: 20)
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: 216, height: 28))
        holder.addSubview(slider)
        let volItem = NSMenuItem(); volItem.view = holder
        sub.addItem(volItem)
        sub.addItem(.separator())
        let quiet = NSMenuItem(title: TypingMenu.quietOnCallsTitle, action: #selector(toggleQuietOnCalls), keyEquivalent: "")
        quiet.target = self
        quiet.state = settings.quietOnCalls ? .on : .off
        quiet.toolTip = TypingMenu.quietOnCallsTooltip
        sub.addItem(quiet)
        sub.addItem(.separator())
        let folder = NSMenuItem(title: TypingMenu.openPacksFolder, action: #selector(openPacksFolder), keyEquivalent: "")
        folder.target = self
        sub.addItem(folder)
        let profile = NSMenuItem(title: TypingMenu.profileMenuTitle(current), action: nil, keyEquivalent: "")
        profile.submenu = sub
        items.append(profile)
        return items
    }

    /// Refreshes the WPM line once a second while the dropdown is open (an open NSMenu runs in
    /// the event-tracking run loop mode, hence `.common`).
    func menuOpened() {
        guard wpmItem != nil, liveTimer == nil else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let item = self.wpmItem else { return }
            item.attributedTitle = self.wpmAttributed(self.wpmText())
            self.refreshNote()
        }
        RunLoop.main.add(t, forMode: .common)
        liveTimer = t
    }

    func menuClosed() {
        liveTimer?.invalidate(); liveTimer = nil
        wpmItem = nil
        noteItem = nil
    }

    /// Updates the status note in an open dropdown (mic in use / free, secure input).
    private func refreshNote() {
        guard let item = noteItem else { return }
        let note = TypingMenu.statusNote(enabled: settings.enabled, listener: listenerState, secureInput: IsSecureEventInputEnabled(),
                                         callMuted: settings.quietOnCalls && mic.inUse)
        item.title = "    " + (note ?? "")
        item.isHidden = note == nil
    }

    private func wpmText() -> String {
        TypingMenu.wpmLine(live: meter.liveWPM(at: ProcessInfo.processInfo.systemUptime), today: meter.today(TypingStats.dayKey(Date())))
    }

    private func wpmAttributed(_ s: String) -> NSAttributedString {
        NSAttributedString(string: "    " + s, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)])
    }

    // MARK: actions

    @objc private func toggleEnabled() {
        settings.enabled.toggle()
        settings.save(to: defaults)
        settings.enabled ? start(prompt: true) : stop()
    }

    @objc private func toggleQuietOnCalls() {
        settings.quietOnCalls.toggle()
        settings.save(to: defaults)
        syncMicMonitor()
        refreshNote()
    }

    @objc private func pickProfile(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        settings.profile = id
        settings.save(to: defaults)
        reloadPacks { [weak self] in self?.preview() }   // preview once the new pack has decoded
    }

    @objc private func volumeChanged(_ sender: NSSlider) {
        settings.volume = KeySoundSettings.clamp(sender.doubleValue)
        settings.save(to: defaults)
        player?.volume = settings.volume
        preview()
    }

    /// One click (F key: press, then its release) so a profile or volume change can be heard,
    /// only when clicks would play. The release follows the keyboard's rules: only after a
    /// press that really played, from the same pack, and only if clicks are still allowed then
    /// (a call may have started in the 90 ms between).
    private func preview() {
        let key = KeySoundController.previewKey
        guard gateOpen, let player, previewPairing.keyDown(key, isRepeat: false), player.press(key) else { return }
        previewPairing.pressSounded(key, generation: player.generation)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) { [weak self] in
            guard let self, let player = self.player else { return }
            if self.previewPairing.keyUp(key, generation: player.generation) && self.gateOpen { player.release(key) }
        }
    }

    private static let previewKey: UInt16 = 3

    @objc private func openInputMonitoring() {
        KeyListener.requestAccess()
        NSWorkspace.shared.open(KeyListener.settingsURL)
    }

    @objc private func openPacksFolder() {
        try? FileManager.default.createDirectory(at: Paths.keySoundsDir, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([Paths.keySoundsDir])
    }
}
