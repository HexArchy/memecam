import Foundation
import Testing
@testable import MemeCamCore

private func launch(pid: Int32, marker: URL) throws {
    let p = Process()
    p.executableURL = URL(filePath: "/bin/sh")
    p.arguments = Relaunch.launcherArguments(pid: pid, appPath: marker.path, opener: "/usr/bin/touch")
    try p.run()
    p.waitUntilExit() // the launcher only forks the waiter
    #expect(p.terminationStatus == 0)
}

private func waitForFile(_ url: URL, seconds: Double) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if FileManager.default.fileExists(atPath: url.path) { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return FileManager.default.fileExists(atPath: url.path)
}

@Test func relaunchWaitsForTheOldProcessToExit() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appending(path: "MemeCam Relaunch '$HOME' `id` \(UUID().uuidString)")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let marker = root.appending(path: "Nikita's $Apps; rm -rf x.app")

    let old = Process()
    old.executableURL = URL(filePath: "/bin/sleep")
    old.arguments = ["1"]
    try old.run()
    try launch(pid: old.processIdentifier, marker: marker)

    try await Task.sleep(for: .milliseconds(400))
    #expect(!fm.fileExists(atPath: marker.path), "opened while the old instance was still running")
    old.waitUntilExit()
    #expect(await waitForFile(marker, seconds: 5))
}

@Test func relaunchOpensRightAwayWhenAlreadyGone() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appending(path: "MemeCamRelaunch-\(UUID().uuidString)")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let marker = root.appending(path: "MemeCam.app")
    let done = Process()
    done.executableURL = URL(filePath: "/usr/bin/true")
    try done.run()
    done.waitUntilExit()
    try launch(pid: done.processIdentifier, marker: marker)
    #expect(await waitForFile(marker, seconds: 3))
}
