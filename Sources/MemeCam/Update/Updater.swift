import AppKit
import Foundation
import Observation
import MemeCamCore
import os
import Security

/// Self-updater that follows GitHub Releases of HexArchy/memecam.
///
/// Check: GET /repos/{repo}/releases/latest → compare `tag_name` with CFBundleShortVersionString.
/// Install: download the DMG asset → mount read-only → copy MemeCam.app out → verify its code
/// signature against a requirement pinned to *this* app's Team ID (Apple-anchored) and the same
/// bundle id → Gatekeeper assessment (notarization) → a detached helper swaps the bundle in
/// /Applications once this process exits and relaunches it. Nothing unverified is ever run.
/// Everything after the download runs off the main actor; the helper logs to ~/Library/Logs/MemeCam/update.log.
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
    /// Set once the swap helper is waiting for this process to quit; a second install would race it.
    private var swapScheduled = false

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
        // Without a real version we can't tell what's newer — never update (avoids update loops).
        guard currentVersion.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil else {
            state = userInitiated ? .failed(String(localized: "This build has no version number, so it can't update itself.")) : .idle
            return
        }
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
            state = userInitiated ? .failed(String(localized: "Couldn't check for updates: \(error.localizedDescription)")) : .idle
        }
    }

    func dismiss() {
        if case .available = state { state = .idle } else if case .failed = state { state = .idle }
        else if case .upToDate = state { state = .idle }
    }

    func installUpdate() async {
        // Re-entrancy guard: a double click must not download twice.
        if case .downloading = state { return }
        if case .installing = state { return }
        guard !swapScheduled else {
            state = .failed(String(localized: "The update is ready. Quit MemeCam to finish installing it."))
            return
        }
        guard let release = latest, let asset = release.assets.first(where: { $0.name.hasSuffix(".dmg") }) else { return }
        let dest = Bundle.main.bundleURL
        // Fail before downloading 50 MB if the swap can't happen anyway.
        guard Self.canReplace(dest) else {
            state = .failed(UpdateError.notWritable.errorDescription ?? "")
            return
        }
        state = .downloading
        let work = FileManager.default.temporaryDirectory.appending(path: "MemeCamUpdate-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let dmg = work.appending(path: "MemeCam.dmg")
            try await Self.download(asset.browser_download_url, to: dmg)

            state = .installing
            // Mounting, copying, signature checks and spctl take seconds: all of it runs off the main actor.
            try await Self.prepareSwap(dmg: dmg, work: work, destination: dest,
                                       expectedVersion: Self.version(from: release.tag_name))
        } catch {
            try? FileManager.default.removeItem(at: work)
            state = .failed(Self.message(for: error))
            return
        }
        // From here the helper owns `work` (it deletes it after the swap).
        swapScheduled = true
        NSApp.terminate(nil)
        // Still alive: the user (or another app) cancelled the quit. The helper keeps waiting for us to exit.
        try? await Task.sleep(for: .seconds(10))
        state = .failed(String(localized: "The update is ready. Quit MemeCam to finish installing it."))
    }

    // MARK: - Steps (nonisolated, run off the main actor)

    /// The bundle's folder must be writable and the app must not run translocated (read-only mount).
    nonisolated private static func canReplace(_ app: URL) -> Bool {
        let path = app.standardizedFileURL.path
        guard !path.contains("/AppTranslocation/") else { return false }
        return FileManager.default.isWritableFile(atPath: (path as NSString).deletingLastPathComponent)
    }

    /// Downloads to `target`, rejecting HTTP errors and truncated files. Bounded by request/resource timeouts.
    @concurrent nonisolated private static func download(_ url: URL, to target: URL) async throws {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 600
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        let (tmp, response) = try await session.download(from: url)
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw UpdateError.server }
        let size = (try? FileManager.default.attributesOfItem(atPath: tmp.path)[.size] as? Int) ?? 0
        // A dropped connection can still end "successfully" with a short file.
        if size == 0 || (http.expectedContentLength > 0 && Int64(size) != http.expectedContentLength) {
            throw UpdateError.incomplete
        }
        try FileManager.default.moveItem(at: tmp, to: target)
    }

    /// Extracts and verifies the new app, then starts the swap helper. Throws before anything is changed.
    @concurrent nonisolated private static func prepareSwap(dmg: URL, work: URL, destination: URL,
                                                            expectedVersion: String) async throws {
        let newApp = try await extractApp(from: dmg, into: work)
        try await verify(newApp, expectedVersion: expectedVersion)
        try? FileManager.default.removeItem(at: dmg) // not needed any more; the helper deletes `work` later
        try scheduleSwapAndRelaunch(newApp: newApp, destination: destination, work: work)
    }

    nonisolated private static func extractApp(from dmg: URL, into work: URL) async throws -> URL {
        let mount = work.appending(path: "mnt")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try await run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen",
                                           "-mountpoint", mount.path], timeout: 60)
        do {
            let source = mount.appending(path: "MemeCam.app")
            guard FileManager.default.fileExists(atPath: source.path) else { throw UpdateError.badPackage }
            let target = work.appending(path: "MemeCam.app")
            try await run("/usr/bin/ditto", [source.path, target.path], timeout: 300)
            await detach(mount)
            return target
        } catch {
            await detach(mount)
            throw error
        }
    }

    nonisolated private static func detach(_ mount: URL) async {
        _ = try? await run("/usr/bin/hdiutil", ["detach", mount.path, "-force"], timeout: 60)
    }

    /// The new bundle must be signed by the same Apple-issued Team ID as this app, have the same
    /// bundle identifier and the advertised version, and pass Gatekeeper (notarized).
    nonisolated private static func verify(_ app: URL, expectedVersion: String) async throws {
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
        // Gatekeeper: notarized Developer ID (fails for dev-signed or tampered builds). May do an online
        // notarization lookup, hence the timeout.
        try await run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path], timeout: 60)
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

    /// ~/Library/Logs/MemeCam/update.log: the swap helper appends its progress and any failure here.
    nonisolated static var logURL: URL {
        URL.libraryDirectory.appending(path: "Logs/MemeCam/update.log")
    }

    /// Starts the detached swap helper (`UpdateSwap.script`): it waits for this process to exit, swaps the
    /// bundle (keeping the old one until the copy succeeds), relaunches and logs every step.
    nonisolated private static func scheduleSwapAndRelaunch(newApp: URL, destination: URL, work: URL) throws {
        guard canReplace(destination) else { throw UpdateError.notWritable }
        let script = work.appending(path: "swap.sh")
        try UpdateSwap.script.write(to: script, atomically: true, encoding: .utf8)
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let args = UpdateSwap.arguments(pid: ProcessInfo.processInfo.processIdentifier, destination: destination.path,
                                        newApp: newApp.path, work: work.path, log: logURL.path)
        // Constant launcher: `sh -c` backgrounds the helper under nohup so it outlives us; the script path is
        // `$0` and the paths are `$@`, never part of shell source.
        let p = Process()
        p.executableURL = URL(filePath: "/bin/sh")
        p.arguments = ["-c", #"/usr/bin/nohup /bin/sh "$0" "$@" >/dev/null 2>&1 &"#, script.path] + args
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit() // returns at once: the outer shell only forks the helper
        guard p.terminationStatus == 0 else { throw UpdateError.tool("sh", "could not start the update helper") }
    }

    /// Runs a tool with no stdin and its output in a temp file (a pipe would deadlock once it fills up),
    /// terminating it after `timeout` (SIGTERM, then SIGKILL 5 s later).
    @discardableResult
    nonisolated private static func run(_ tool: String, _ args: [String], timeout: TimeInterval) async throws -> String {
        let name = (tool as NSString).lastPathComponent
        let outURL = FileManager.default.temporaryDirectory.appending(path: "MemeCamUpdate-\(UUID().uuidString).log")
        guard FileManager.default.createFile(atPath: outURL.path, contents: nil) else { throw UpdateError.tool(name, "no temp file") }
        defer { try? FileManager.default.removeItem(at: outURL) }
        let out = try FileHandle(forWritingTo: outURL)
        defer { try? out.close() }

        let p = Process()
        p.executableURL = URL(filePath: tool)
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = out
        p.standardError = out
        let timedOut = OSAllocatedUnfairLock(initialState: false)
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            p.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try p.run() } catch {
                p.terminationHandler = nil
                continuation.resume(throwing: error)
                return
            }
            let pid = p.processIdentifier
            let watchdog = DispatchQueue.global(qos: .utility)
            watchdog.asyncAfter(deadline: .now() + timeout) { [weak p] in
                guard let p, p.isRunning, p.processIdentifier == pid else { return }
                timedOut.withLock { $0 = true }
                p.terminate()
                watchdog.asyncAfter(deadline: .now() + 5) { [weak p] in
                    if let p, p.isRunning { kill(pid, SIGKILL) }
                }
            }
        }
        let text = (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
        if timedOut.withLock({ $0 }) { throw UpdateError.timedOut(name) }
        guard status == 0 else { throw UpdateError.tool(name, text) }
        return text
    }

    /// User-facing text for anything `installUpdate` can throw.
    nonisolated private static func message(for error: any Error) -> String {
        if let e = error as? UpdateError { return e.errorDescription ?? String(localized: "The update failed.") }
        if let e = error as? URLError {
            switch e.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
                return String(localized: "You're offline. Connect to the internet and try again.")
            case .timedOut:
                return String(localized: "The download timed out. Try again later.")
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .badServerResponse:
                return String(localized: "GitHub can't be reached right now. Try again later.")
            default:
                return String(localized: "The download failed: \(e.localizedDescription)")
            }
        }
        if let e = error as? CocoaError, e.code == .fileWriteOutOfSpace {
            return String(localized: "There isn't enough disk space to download the update.")
        }
        return error.localizedDescription
    }

    // MARK: - Versions

    nonisolated static func version(from tag: String) -> String { AppVersion.normalize(tag) }
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool { AppVersion.isNewer(a, than: b) }

    enum UpdateError: LocalizedError {
        case server, incomplete, badPackage, signature, unsigned, notWritable
        case tool(String, String)
        case timedOut(String)
        var errorDescription: String? {
            switch self {
            case .server: String(localized: "GitHub didn't respond. Try again later.")
            case .incomplete: String(localized: "The download was incomplete. Check your connection and try again.")
            case .badPackage: String(localized: "The downloaded update doesn't contain a valid MemeCam.")
            case .signature: String(localized: "The update's signature doesn't match this app. It was not installed.")
            case .unsigned: String(localized: "This build isn't signed, so it can't verify updates.")
            case .notWritable: String(localized: "MemeCam can't replace itself here: its folder isn't writable or it runs from a disk image. Move it to Applications (or ask an administrator) and try again.")
            case .tool(let name, let output): String(localized: "\(name) failed: \(String(output.prefix(200)))")
            case .timedOut(let name): String(localized: "\(name) didn't finish in time. Try again later.")
            }
        }
    }
}
