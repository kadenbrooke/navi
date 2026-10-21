import AppKit
import CoreGraphics
import PetCore

/// Global key listener for typing sounds (key-down / key-up, modifier flag changes, and the
/// media-key events a MacBook's top row sends): a listen-only Quartz event tap (it can never
/// block, delay or change a key press). Needs macOS Input Monitoring permission; without it the
/// tap cannot be created and `start()` returns false, and Navi keeps working without it.
///
/// Privacy: the tap hands over the virtual key code and the auto-repeat flag, which the caller
/// uses in memory only (an index into the precomputed sound tables and the held-keys set that
/// pairs releases with presses). Nothing here or there stores, logs or sends either. While a password field has secure input on, macOS delivers no key events to taps at
/// all, so typing sounds and WPM pause by themselves.
final class KeyListener {
    // Every callback gets the event's own time (seconds on the uptime clock, `EventClock`), not
    // the time the callback ran: the main thread may be busy (the audio engine waking takes
    // ~150 ms), and two reports of one key press must keep their real spacing.

    /// keyCode, isRepeat, raw CGEventFlags (⌘ / ⌃ held, and every modifier's live state), time.
    /// Called on the main run loop.
    var onKeyDown: ((UInt16, Bool, UInt64, TimeInterval) -> Void)?
    /// keyCode, time. Called on the main run loop.
    var onKeyUp: ((UInt16, TimeInterval) -> Void)?
    /// keyCode, raw CGEventFlags, time: a modifier (or caps lock) changed. Called on the main run loop.
    var onFlagsChanged: ((UInt16, UInt64, TimeInterval) -> Void)?
    /// subtype, data1, time of a system-defined event (media keys: brightness, volume, play…).
    /// Called on the main run loop.
    var onSystemDefined: ((Int, Int, TimeInterval) -> Void)?

    private static let timebase: mach_timebase_info_data_t = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return tb
    }()

    static func time(_ event: CGEvent) -> TimeInterval {
        EventClock.seconds(timestamp: event.timestamp, nowNanos: clock_gettime_nsec_np(CLOCK_UPTIME_RAW),
                           numer: timebase.numer, denom: timebase.denom)
    }
    /// macOS disabled the tap (timeout or user input) and Navi re-enabled it: key events in
    /// between were lost, so held-key state is stale. Called on the main run loop.
    var onTapReset: (() -> Void)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    var isRunning: Bool { tap != nil }

    /// Input Monitoring granted (no prompt).
    static var hasAccess: Bool { CGPreflightListenEventAccess() }

    /// Shows the system prompt the first time and adds Navi to System Settings → Privacy &
    /// Security → Input Monitoring. Later calls return the current answer without a prompt.
    @discardableResult
    static func requestAccess() -> Bool { CGRequestListenEventAccess() }

    /// NX_SYSDEFINED: not in `CGEventType`'s named cases.
    private static let systemDefined: UInt32 = 14

    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!

    /// True when the tap is up (already or now).
    @discardableResult
    func start() -> Bool {
        if tap != nil { return true }
        guard KeyListener.hasAccess else { return false }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
            | CGEventMask(1 << CGEventType.flagsChanged.rawValue) | CGEventMask(1 << KeyListener.systemDefined)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<KeyListener>.fromOpaque(refcon).takeUnretainedValue()
            switch type {
            case .tapDisabledByTimeout, .tapDisabledByUserInput:
                if let t = me.tap { CGEvent.tapEnable(tap: t, enable: true) }
                me.onTapReset?()
            case .keyDown:
                let code = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
                let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                me.onKeyDown?(code, isRepeat, event.flags.rawValue, KeyListener.time(event))
            case .keyUp:
                me.onKeyUp?(UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)), KeyListener.time(event))
            case .flagsChanged:
                me.onFlagsChanged?(UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)), event.flags.rawValue,
                                   KeyListener.time(event))
            default:
                // Media keys: subtype and data1 only exist on the NSEvent form.
                if type.rawValue == KeyListener.systemDefined, let ns = NSEvent(cgEvent: event), ns.type == .systemDefined {
                    me.onSystemDefined?(Int(ns.subtype.rawValue), ns.data1, KeyListener.time(event))
                }
            }
            return Unmanaged.passUnretained(event)
        }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                        eventsOfInterest: mask, callback: callback,
                                        userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        tap = t; source = src
        NSLog("Navi: typing sounds listening (Input Monitoring granted)")
        return true
    }

    func stop() {
        guard let t = tap else { return }
        CGEvent.tapEnable(tap: t, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(t)
        tap = nil; source = nil
        NSLog("Navi: typing sounds stopped listening")
    }

    deinit { stop() }
}
