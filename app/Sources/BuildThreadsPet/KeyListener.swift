import CoreGraphics
import Foundation

/// Global key-down listener for typing sounds: a listen-only Quartz event tap (it can never
/// block, delay or change a key press). Needs macOS Input Monitoring permission; without it the
/// tap cannot be created and `start()` returns false, and Navi keeps working without it.
///
/// Privacy: the tap hands over the virtual key code and the auto-repeat flag, and the caller
/// reduces them at once to a coarse `KeyClass` (`KeyEventFilter`). Nothing here stores or logs
/// either. While a password field has secure input on, macOS delivers no key events to taps at
/// all, so typing sounds and WPM pause by themselves.
final class KeyListener {
    /// keyCode, isRepeat, ⌘ held, ⌃ held. Called on the main run loop.
    var onKeyDown: ((UInt16, Bool, Bool, Bool) -> Void)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    var isRunning: Bool { tap != nil }

    /// Input Monitoring granted (no prompt).
    static var hasAccess: Bool { CGPreflightListenEventAccess() }

    /// Shows the system prompt the first time and adds Navi to System Settings → Privacy &
    /// Security → Input Monitoring. Later calls return the current answer without a prompt.
    @discardableResult
    static func requestAccess() -> Bool { CGRequestListenEventAccess() }

    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!

    /// True when the tap is up (already or now).
    @discardableResult
    func start() -> Bool {
        if tap != nil { return true }
        guard KeyListener.hasAccess else { return false }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<KeyListener>.fromOpaque(refcon).takeUnretainedValue()
            switch type {
            case .tapDisabledByTimeout, .tapDisabledByUserInput:
                if let t = me.tap { CGEvent.tapEnable(tap: t, enable: true) }
            case .keyDown:
                let code = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
                let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                let flags = event.flags
                me.onKeyDown?(code, isRepeat, flags.contains(.maskCommand), flags.contains(.maskControl))
            default:
                break
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
