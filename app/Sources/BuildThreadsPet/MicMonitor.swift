import CoreAudio
import Foundation
import PetCore

/// *Quiet on calls*: knows whether any other app is using a microphone, without microphone
/// permission and without ever opening one. It reads CoreAudio's own bookkeeping (which
/// processes run audio input, on which devices, and which devices are running) and applies
/// `MicActivity.inUse`. Event-driven: CoreAudio property listeners fire on change, so there is
/// no polling; nothing runs while it is stopped. All callbacks land on the main queue.
final class MicMonitor {
    private(set) var inUse = false
    var onChange: ((Bool) -> Void)?

    private var running = false
    private var scheduled = false
    private var needsRebuild = false
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private let selfPID = ProcessInfo.processInfo.processIdentifier
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    func start() {
        guard !running else { return }
        running = true
        rebuild()
    }

    func stop() {
        guard running else { return }
        running = false
        removeListeners()
        set(false)
    }

    deinit { removeListeners() }

    // MARK: listeners

    /// Listens on the process and device lists (a new call app or headset appears), on every
    /// process's input state and devices, and on every input-capable device's running state.
    private func rebuild() {
        removeListeners()
        guard running else { return }
        listen(Self.system, kAudioHardwarePropertyProcessObjectList, rebuild: true)
        listen(Self.system, kAudioHardwarePropertyDevices, rebuild: true)
        for p in Self.ids(Self.system, kAudioHardwarePropertyProcessObjectList) {
            listen(p, kAudioProcessPropertyIsRunningInput)
            listen(p, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeInput)
        }
        for d in Self.inputDevices() { listen(d, kAudioDevicePropertyDeviceIsRunningSomewhere) }
        recompute()
    }

    private func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, rebuild: Bool = false) {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.schedule(rebuild: rebuild) }
        if AudioObjectAddPropertyListenerBlock(object, &address, DispatchQueue.main, block) == noErr {
            listeners.append((object, address, block))
        }
    }

    private func removeListeners() {
        for (object, address, block) in listeners {
            var a = address
            AudioObjectRemovePropertyListenerBlock(object, &a, DispatchQueue.main, block)
        }
        listeners = []
    }

    /// Several properties change at once when a call starts: one recompute for the burst.
    private func schedule(rebuild: Bool) {
        needsRebuild = needsRebuild || rebuild
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            let again = self.needsRebuild
            self.needsRebuild = false
            again ? self.rebuild() : self.recompute()
        }
    }

    private func recompute() {
        guard running else { return }
        let processes = Self.ids(Self.system, kAudioHardwarePropertyProcessObjectList).compactMap { p -> MicActivity.Process? in
            guard Self.u32(p, kAudioProcessPropertyIsRunningInput) != 0 else { return nil }
            return MicActivity.Process(pid: Int32(bitPattern: Self.u32(p, kAudioProcessPropertyPID)), runningInput: true,
                                       inputDevices: Self.ids(p, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeInput))
        }
        let running = Set(Self.inputDevices().filter { Self.u32($0, kAudioDevicePropertyDeviceIsRunningSomewhere) != 0 })
        set(MicActivity.inUse(processes, runningDevices: running, selfPID: selfPID))
    }

    private func set(_ v: Bool) {
        guard v != inUse else { return }
        inUse = v
        onChange?(v)
    }

    // MARK: CoreAudio reads

    private static func inputDevices() -> [AudioObjectID] {
        ids(system, kAudioHardwarePropertyDevices).filter { !ids($0, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput).isEmpty }
    }

    private static func u32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32 {
        var a = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var v: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &a, 0, nil, &size, &v) == noErr ? v : 0
    }

    private static func ids(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                            scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var a = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var out = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &a, 0, nil, &size, &out) == noErr else { return [] }
        return Array(out.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }
}
