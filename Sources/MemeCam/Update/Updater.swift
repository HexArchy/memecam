import AppKit
import Foundation
import Observation
import MemeCamCore
import Security

/// Self-updater that follows GitHub Releases of HexArchy/memecam.
///
/// Check: GET /repos/{repo}/releases/latest → compare `tag_name` with CFBundleShortVersionString.
/// Install: download the DMG asset → mount read-only → copy MemeCam.app out → verify its code
/// signature against a requirement pinned to *this* app's Team ID (Apple-anchored) and the same
/// bundle id → Gatekeeper assessment (notarization) → a detached helper swaps the bundle in
/// /Applications once this process exits and relaunches it. Nothing unverified is ever run.
@MainActor @Observable
final class Updater {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String, notes: String)
        case downloading
        case installing
        case failed(String)
    }

    struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }
        let tag_name: String
        let body: String?
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
    }

    static let repo = "HexArchy/memecam"
    private(set) var state: State = .idle
    var automaticChecks: Bool {
        didSet { UserDefaults.standard.set(automaticChecks, forKey: "autoUpdateChecks") }
    }

    private var latest: Release?
    private var timer: Timer?

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    var updateAvailable: Bool {
        if case .available = state { return true }
        return false
    }

    init() {
        automaticChecks = UserDefaults.standard.object(forKey: "autoUpdateChecks") as? Bool ?? true
    }

    /// Checks shortly after launch and then every 6 hours while automatic checks are on.
    func start() {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return } // not for `swift run`
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            if UserDefaults.standard.bool(forKey: "MemeCamInstallUpdateOnLaunch") {
                await self?.check(userInitiated: true)
            } else {
                await self?.checkIfDue()
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkIfDue() }
        }
    }

    private func checkIfDue() async {
        guard automaticChecks else { return }
        await check(userInitiated: false)
    }

    func check(userInitiated: Bool) async {
        if case .downloading = state { return }
        if case .installing = state { return }
        state = .checking
        do {
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("MemeCam/\(currentVersion)", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.server }
            let release = try JSONDecoder().decode(Release.self, from: data)
            let version = Self.version(from: release.tag_name)
            if !release.draft, !release.prerelease, Self.isNewer(version, than: currentVersion),
               release.assets.contains(where: { $0.name.hasSuffix(".dmg") }) {
                latest = release
                state = .available(version: version, notes: release.body ?? "")
                // `-MemeCamInstallUpdateOnLaunch YES` (launch argument) installs right away — used to
                // test the update path end to end.
                if UserDefaults.standard.bool(forKey: "MemeCamInstallUpdateOnLaunch") { await installUpdate() }
            } else {
                state = userInitiated ? .upToDate : .idle
            }
        } catch {
            state = userInitiated ? .failed("Couldn't check for updates: \(error.localizedDescription)") : .idle
        }
    }

    func dismiss() {
        if case .available = state { state = .idle } else if case .failed = state { state = .idle }
        else if case .upToDate = state { state = .idle }
    }

    func installUpdate() async {
        guard let release = latest, let asset = release.assets.first(where: { $0.name.hasSuffix(".dmg") }) else { return }
        state = .downloading
        do {
            let work = FileManager.default.temporaryDirectory.appending(path: "MemeCamUpdate-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let (tmp, response) = try await URLSession.shared.download(from: asset.browser_download_url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.server }
            let dmg = work.appending(path: "MemeCam.dmg")
            try FileManager.default.moveItem(at: tmp, to: dmg)

            state = .installing
            let newApp = try await Task.detached { try Self.extractApp(from: dmg, into: work) }.value
            try Self.verify(newApp, expectedVersion: Self.version(from: release.tag_name))
            try Self.scheduleSwapAndRelaunch(newApp: newApp, work: work)
            NSApp.terminate(nil)
        } catch {
            state = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    // MARK: - Steps (nonisolated, run off the main actor)

    nonisolated private static func extractApp(from dmg: URL, into work: URL) throws -> URL {
        let mount = work.appending(path: "mnt")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path])
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
        let source = mount.appending(path: "MemeCam.app")
        guard FileManager.default.fileExists(atPath: source.path) else { throw UpdateError.badPackage }
        let target = work.appending(path: "MemeCam.app")
        try run("/usr/bin/ditto", [source.path, target.path])
        return target
    }

    /// The new bundle must be signed by the same Apple-issued Team ID as this app, have the same
    /// bundle identifier and the advertised version, and pass Gatekeeper (notarized).
    nonisolated private static func verify(_ app: URL, expectedVersion: String) throws {
        guard let team = currentTeamID() else { throw UpdateError.unsigned }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw UpdateError.signature
        }
        let req = "anchor apple generic and identifier \"com.hexarch.memecam\" and certificate leaf[subject.OU] = \"\(team)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(req as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode
                                                          | kSecCSStrictValidate), requirement) == errSecSuccess
        else { throw UpdateError.signature }

        let info = NSDictionary(contentsOf: app.appending(path: "Contents/Info.plist"))
        guard info?["CFBundleShortVersionString"] as? String == expectedVersion else { throw UpdateError.badPackage }
        // Gatekeeper: notarized Developer ID (fails for dev-signed or tampered builds).
        try run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path])
    }

    nonisolated private static func currentTeamID() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess
        else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// A tiny detached shell script waits for this process to exit, swaps the bundle atomically
    /// (keeping the old one until the copy succeeds) and relaunches.
    nonisolated private static func scheduleSwapAndRelaunch(newApp: URL, work: URL) throws {
        let dest = Bundle.main.bundleURL.path
        guard FileManager.default.isWritableFile(atPath: (dest as NSString).deletingLastPathComponent) else {
            throw UpdateError.notWritable
        }
        let script = work.appending(path: "swap.sh")
        let body = """
        #!/bin/sh
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        DEST='\(dest)'; NEW='\(newApp.path)'
        rm -rf "$DEST.old"
        if mv "$DEST" "$DEST.old" && /usr/bin/ditto "$NEW" "$DEST"; then
          rm -rf "$DEST.old"
        else
          rm -rf "$DEST"; mv "$DEST.old" "$DEST"
        fi
        /usr/bin/xattr -dr com.apple.quarantine "$DEST" 2>/dev/null
        /usr/bin/open "$DEST"
        rm -rf '\(work.path)'
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(filePath: "/bin/sh")
        p.arguments = ["-c", "nohup /bin/sh '\(script.path)' >/dev/null 2>&1 &"]
        try p.run()
        p.waitUntilExit()
    }

    @discardableResult
    nonisolated private static func run(_ tool: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(filePath: tool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        p.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard p.terminationStatus == 0 else { throw UpdateError.tool((tool as NSString).lastPathComponent, text) }
        return text
    }

    // MARK: - Versions

    nonisolated static func version(from tag: String) -> String { AppVersion.normalize(tag) }
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool { AppVersion.isNewer(a, than: b) }

    enum UpdateError: LocalizedError {
        case server, badPackage, signature, unsigned, notWritable
        case tool(String, String)
        var errorDescription: String? {
            switch self {
            case .server: "GitHub didn't respond. Try again later."
            case .badPackage: "The downloaded update doesn't contain a valid MemeCam."
            case .signature: "The update's signature doesn't match this app. It was not installed."
            case .unsigned: "This build isn't signed, so it can't verify updates."
            case .notWritable: "MemeCam can't replace itself here. Move it to Applications and try again."
            case .tool(let name, let output): "\(name) failed: \(output.prefix(200))"
            }
        }
    }
}
