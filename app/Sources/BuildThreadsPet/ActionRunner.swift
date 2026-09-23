import AppKit
import PetCore

/// Runs a thread action's shell command via /bin/sh, in the thread's worktree.
/// Only ever called from a click. Destructive commands ask first.
enum ActionRunner {
    static func run(_ action: ThreadAction, for thread: BuildThread) {
        if action.isDestructive {
            let alert = NSAlert()
            alert.messageText = "\(action.label) — \(thread.name)?"
            alert.informativeText = "This runs:\n\(action.command)\n\nIt can't be undone from the pet."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Run")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        NSLog("Navi: run [%@] %@", action.label, action.command)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", action.command]
        if let wt = thread.worktreePath, FileManager.default.fileExists(atPath: wt) {
            p.currentDirectoryURL = URL(fileURLWithPath: wt)
        }
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch {
            NSLog("Navi: action failed: \(error)")
        }
    }
}
