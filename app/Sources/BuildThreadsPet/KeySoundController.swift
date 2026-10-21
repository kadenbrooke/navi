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
    private var packs: [SoundPack] = [SoundPack.synth]
    private var retryTimer: Timer?
    private var saveTimer: Timer?
    private var liveTimer: Timer?
    private weak var wpmItem: NSMenuItem?

    /// Master Sound toggle (`config.params.sound`) and hidden state, read on every press.
    var soundOn: () -> Bool = { true }
    var hidden: () -> Bool = { false }

    override init() {
        settings = KeySoundSettings(store: UserDefaults.standard)
        let today = TypingStats.dayKey(Date())
        meter = TypingMeter(stats: TypingStats.load(from: UserDefaults.standard, today: today) ?? TypingStats(day: today))
        super.init()
        listener.onKeyDown = { [weak self] code, isRepeat, command, control in
            self?.keyDown(code: code, isRepeat: isRepeat, command: command, control: control)
        }
        if settings.enabled { start(prompt: false) }
    }

    private var listenerState: TypingMenu.Listener {
        guard settings.enabled else { return .off }
        return listener.isRunning ? .running : .needsPermission
    }

    // MARK: key presses (main run loop)

    private func keyDown(code: UInt16, isRepeat: Bool, command: Bool, control: Bool) {
        // The key code stops here: only the coarse class and the press time go on.
        guard let press = KeyEventFilter.press(keyCode: code, isRepeat: isRepeat, command: command, control: control) else { return }
        if KeySoundGate.shouldPlay(enabled: settings.enabled, soundOn: soundOn(), hidden: hidden()) { player?.play(press.keyClass) }
        if press.countsAsTyping { meter.record(at: ProcessInfo.processInfo.systemUptime, day: TypingStats.dayKey(Date())) }
    }

    // MARK: on / off

    private func start(prompt: Bool) {
        if player == nil {
            player = KeySoundPlayer()
            player?.volume = settings.volume
            reloadPacks(force: true)
        }
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
        let pack = SoundPackLibrary.resolve(settings.profile, in: packs)
        guard let player, force || player.requestedID != pack.id else { done?(); return }
        player.load(pack) { _ in done?() }
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
                                   muteReason: KeySoundGate.muteReason(soundOn: soundOn(), hidden: hidden())) {
            switch row {
            case .stats:
                let wpm = NSMenuItem(title: wpmText(), action: nil, keyEquivalent: "")
                wpm.attributedTitle = wpmAttributed(wpmText())
                items.append(wpm)
                wpmItem = wpm
            case .note(let note):
                let m = NSMenuItem(title: "    " + note, action: nil, keyEquivalent: "")
                m.isEnabled = false
                items.append(m)
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
        }
        RunLoop.main.add(t, forMode: .common)
        liveTimer = t
    }

    func menuClosed() {
        liveTimer?.invalidate(); liveTimer = nil
        wpmItem = nil
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

    /// One click so a profile or volume change can be heard (only when clicks would play).
    private func preview() {
        guard KeySoundGate.shouldPlay(enabled: settings.enabled, soundOn: soundOn(), hidden: hidden()) else { return }
        player?.play(.other)
    }

    @objc private func openInputMonitoring() {
        KeyListener.requestAccess()
        NSWorkspace.shared.open(KeyListener.settingsURL)
    }

    @objc private func openPacksFolder() {
        try? FileManager.default.createDirectory(at: Paths.keySoundsDir, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([Paths.keySoundsDir])
    }
}
