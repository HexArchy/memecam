import AppKit
import MemeCamCore

/// Quits, and a detached helper reopens this bundle once this process is gone, so two instances never
/// run side by side (they would fight over the camera, hotkeys and the virtual-camera sink).
@MainActor
enum AppRelaunch {
    /// What to bring back after a relaunch MemeCam did on its own (one-shot, read at the next launch).
    struct Resume: Codable {
        var camera: Bool
        var testPattern: Bool
    }

    private static let resumeKey = "relaunchResume"

    /// Starts the helper and quits. Returns false (and keeps running) when the helper couldn't start.
    @discardableResult
    static func relaunch(resume: Resume? = nil) -> Bool {
        let p = Process()
        p.executableURL = URL(filePath: "/bin/sh")
        p.arguments = Relaunch.launcherArguments(pid: ProcessInfo.processInfo.processIdentifier,
                                                 appPath: Bundle.main.bundleURL.path)
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit() // returns at once: the launcher only forks the helper
        } catch {
            return false
        }
        guard p.terminationStatus == 0 else { return false }
        if let resume, let data = try? JSONEncoder().encode(resume) {
            UserDefaults.standard.set(data, forKey: resumeKey)
        }
        NSApp.terminate(nil)
        return true
    }

    /// The state saved by the last `relaunch(resume:)`, cleared on read.
    static func takeResume() -> Resume? {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: resumeKey) else { return nil }
        defaults.removeObject(forKey: resumeKey)
        return try? JSONDecoder().decode(Resume.self, from: data)
    }
}
