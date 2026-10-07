import AppKit
import MemeCamCore
import SwiftUI

/// In-app language override. Writes `AppleLanguages` into MemeCam's own defaults domain only,
/// so the rest of the Mac keeps its languages. Takes effect on the next launch.
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case english = "en"
    case russian = "ru"

    var id: String { rawValue }

    /// The override stored in MemeCam's own domain (ignores the global list and launch arguments).
    static var stored: AppLanguage {
        let domain = Bundle.main.bundleIdentifier.flatMap { UserDefaults.standard.persistentDomain(forName: $0) }
        guard let code = (domain?["AppleLanguages"] as? [String])?.first else { return .system }
        if code.hasPrefix("ru") { return .russian }
        if code.hasPrefix("en") { return .english }
        return .system
    }

    /// What this process launched with; a restart is needed only when the choice differs.
    static let atLaunch = stored

    func apply() {
        if self == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([rawValue], forKey: "AppleLanguages")
        }
    }
}

struct LanguageSection: View {
    @State private var selection = AppLanguage.stored

    var body: some View {
        Section {
            Picker("Language", selection: $selection) {
                Text("System").tag(AppLanguage.system)
                // Language names stay in their own language so they are findable from any UI language.
                Text(verbatim: "English").tag(AppLanguage.english)
                Text(verbatim: "Русский").tag(AppLanguage.russian)
            }
            .onChange(of: selection) { _, new in new.apply() }
            if selection != AppLanguage.atLaunch {
                LabeledContent {
                    Button("Restart", action: relaunch)
                } label: {
                    Text("Restart MemeCam to apply")
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Label("Language", systemImage: "globe")
        }
    }

    /// Quits, and a detached helper reopens this bundle once this process is gone, so two instances never
    /// run side by side (they would fight over the camera, hotkeys and the virtual-camera sink).
    private func relaunch() {
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
            return
        }
        guard p.terminationStatus == 0 else { return }
        NSApp.terminate(nil)
    }
}
