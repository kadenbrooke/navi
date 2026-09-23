import Foundation
import PetCore

/// Owns the current snapshot. Watches `threads.json` via a vnode DispatchSource on the
/// file *and* its directory (the collector may write-tmp-then-rename), debounces 300ms,
/// and polls every 5s as a safety net. A parse failure keeps the last good snapshot.
final class ThreadsStore {
    private(set) var snapshot: ThreadsSnapshot?
    private(set) var lastError: String?
    private(set) var fileExists = false
    var onChange: ((ThreadsSnapshot?) -> Void)?

    private let url: URL
    private var fileSource: DispatchSourceFileSystemObject?
    private var dirSource: DispatchSourceFileSystemObject?
    private var debounce: DispatchWorkItem?
    private var pollTimer: Timer?

    init(url: URL) {
        self.url = url
    }

    func start() {
        reload()
        watchDirectory()
        watchFile()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.reload() }
        pollTimer?.tolerance = 1
    }

    func stop() {
        fileSource?.cancel(); fileSource = nil
        dirSource?.cancel(); dirSource = nil
        pollTimer?.invalidate(); pollTimer = nil
    }

    /// Re-reads the file. Notifies on the first call and whenever the snapshot changed.
    private var hasNotified = false
    func reload() {
        let previous = snapshot
        fileExists = FileManager.default.fileExists(atPath: url.path)
        if !fileExists {
            lastError = "threads.json not found"
            snapshot = nil
        } else {
            do {
                snapshot = try ThreadsParser.parse(fileAt: url)
                lastError = nil
            } catch {
                // Partial write or garbage: keep the last good snapshot.
                lastError = String(describing: error)
            }
        }
        if !hasNotified || snapshot != previous {
            hasNotified = true
            onChange?(snapshot)
        }
    }

    private func scheduleReload() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.reload()
            self?.watchFile() // the inode may have changed (rename-in-place)
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func watchFile() {
        fileSource?.cancel(); fileSource = nil
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename, .extend, .attrib], queue: .main)
        src.setEventHandler { [weak self] in self?.scheduleReload() }
        src.setCancelHandler { close(fd) }
        src.resume()
        fileSource = src
    }

    private func watchDirectory() {
        let fd = open(url.deletingLastPathComponent().path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in self?.scheduleReload() }
        src.setCancelHandler { close(fd) }
        src.resume()
        dirSource = src
    }
}
