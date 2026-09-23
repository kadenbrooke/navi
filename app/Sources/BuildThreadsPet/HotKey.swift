import Carbon
import AppKit

/// Global hotkeys via Carbon (⌥⌘P sleep/wake, ⌥⌘N hide/show). No accessibility permission
/// needed. Every instance installs its own handler on the app target, so each one checks the
/// hotkey id in the event and only fires its own callback.
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let callback: () -> Void
    private let id: UInt32

    init(id: UInt32 = 1, keyCode: UInt32 = UInt32(kVK_ANSI_P), modifiers: UInt32 = UInt32(cmdKey | optionKey), callback: @escaping () -> Void) {
        self.callback = callback
        self.id = id
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let userData, let event else { return noErr }
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let me = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            if hk.id == me.id { me.callback() }
            return noErr
        }, 1, &spec, selfPtr, &handler)
        let hkID = EventHotKeyID(signature: OSType(0x42545054) /* "BTPT" */, id: id)
        RegisterEventHotKey(keyCode, modifiers, hkID, GetApplicationEventTarget(), 0, &ref)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }
}
