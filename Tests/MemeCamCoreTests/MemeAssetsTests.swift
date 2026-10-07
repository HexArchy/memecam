import Foundation
import Testing
@testable import MemeCamCore

// MARK: - Library paths

@Test func safeFileNamesAcceptGeneratedNames() {
    #expect(LibraryPaths.isSafeFileName("happy-1A2B3C4D.gif"))
    #expect(LibraryPaths.isSafeFileName("my meme (1).png"))
}

@Test func safeFileNamesRejectTraversal() {
    for bad in ["", "..", "../x.gif", "a/b.gif", "/etc/passwd", "..\\x.gif", ".hidden", "x..gif", "a:b", "x\0.gif"] {
        #expect(!LibraryPaths.isSafeFileName(bad), "\(bad)")
    }
}

@Test func containmentUsesStandardizedPaths() {
    let dir = URL(filePath: "/tmp/MemeCamTest/Memes")
    #expect(LibraryPaths.isContained(dir.appending(path: "a.gif"), in: dir))
    #expect(!LibraryPaths.isContained(dir.appending(path: "../a.gif"), in: dir))
    #expect(!LibraryPaths.isContained(URL(filePath: "/tmp/MemeCamTest/MemesEvil/a.gif"), in: dir))
    #expect(!LibraryPaths.isContained(dir, in: dir))
}

// MARK: - Frame sampling

@Test func shortAnimationsKeepEveryFrame() {
    let plan = FrameSampling.plan(delays: [0.1, 0.2, 0.3], maxFrames: 120)
    #expect(plan == [.init(index: 0, duration: 0.1), .init(index: 1, duration: 0.2), .init(index: 2, duration: 0.3)])
}

@Test func longAnimationsAreCappedAndKeepTiming() {
    let delays = (0..<1000).map { Double($0 % 7 + 1) / 100 }
    let plan = FrameSampling.plan(delays: delays, maxFrames: 120)
    #expect(plan.count == 120)
    #expect(plan.first?.index == 0)
    #expect(zip(plan, plan.dropFirst()).allSatisfy { $0.index < $1.index })
    let total = plan.reduce(0) { $0 + $1.duration }
    #expect(abs(total - delays.reduce(0, +)) < 1e-9)
    // Evenly spread: gaps differ by at most one source frame.
    let gaps = zip(plan, plan.dropFirst()).map { $1.index - $0.index }
    #expect((gaps.max() ?? 0) - (gaps.min() ?? 0) <= 1)
}

@Test func emptyPlan() {
    #expect(FrameSampling.plan(delays: [], maxFrames: 10).isEmpty)
    #expect(FrameSampling.plan(delays: [0.1], maxFrames: 0).isEmpty)
}

// MARK: - Byte-bounded LRU

@Test func cacheEvictsLeastRecentlyUsedByCost() {
    var cache = CostLRUCache<String, Int>(budget: 100)
    cache.insert(1, cost: 40, for: "a")
    cache.insert(2, cost: 40, for: "b")
    #expect(cache.value(for: "a") == 1) // "a" becomes most recent
    cache.insert(3, cost: 40, for: "c") // over budget: evicts "b", the least recently used
    #expect(cache.value(for: "b") == nil)
    #expect(cache.value(for: "a") == 1)
    #expect(cache.value(for: "c") == 3)
    #expect(cache.totalCost == 80)
}

@Test func cacheKeepsASingleOversizedEntry() {
    var cache = CostLRUCache<String, Int>(budget: 10)
    cache.insert(1, cost: 5, for: "a")
    cache.insert(2, cost: 50, for: "big")
    #expect(cache.count == 1)
    #expect(cache.value(for: "big") == 2)
    cache.insert(3, cost: 20, for: "big") // replacing updates the cost
    #expect(cache.totalCost == 20)
}

// MARK: - Update swap helper

/// Runs the real swap script on throwaway bundles whose paths contain `'`, spaces, `$` and backticks.
@Test func swapScriptHandlesHostilePaths() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appending(path: "MemeCam Swap '$HOME' `id` \(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    let dest = root.appending(path: "Nikita's $Apps/MemeCam.app")
    let work = root.appending(path: "work 'x'")
    let newApp = work.appending(path: "MemeCam.app")
    let log = root.appending(path: "Logs/update.log")
    try fm.createDirectory(at: dest, withIntermediateDirectories: true)
    try fm.createDirectory(at: newApp, withIntermediateDirectories: true)
    try "old".write(to: dest.appending(path: "version"), atomically: true, encoding: .utf8)
    try "new".write(to: newApp.appending(path: "version"), atomically: true, encoding: .utf8)
    let script = root.appending(path: "swap.sh")
    try UpdateSwap.script.write(to: script, atomically: true, encoding: .utf8)

    // A pid that has already exited, so the script doesn't wait.
    let done = Process()
    done.executableURL = URL(filePath: "/usr/bin/true")
    try done.run()
    done.waitUntilExit()

    let p = Process()
    p.executableURL = URL(filePath: "/bin/sh")
    p.arguments = [script.path] + UpdateSwap.arguments(
        pid: done.processIdentifier, destination: dest.path, newApp: newApp.path, work: work.path,
        log: log.path, opener: "/usr/bin/true")
    try p.run()
    p.waitUntilExit()

    #expect(p.terminationStatus == 0)
    #expect(try String(contentsOf: dest.appending(path: "version"), encoding: .utf8) == "new")
    #expect(!fm.fileExists(atPath: dest.path + ".old"))
    #expect(!fm.fileExists(atPath: work.path))
    let text = try String(contentsOf: log, encoding: .utf8)
    #expect(text.contains("update: installed"))
    #expect(text.contains("update: relaunched"))
    #expect(!text.contains("FAILED"))
}

@Test func swapScriptLeavesTheAppAloneWhenItCannotMoveIt() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appending(path: "MemeCamSwapFail-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    let missing = root.appending(path: "Missing.app") // nothing to move aside
    let newApp = root.appending(path: "work/MemeCam.app")
    let log = root.appending(path: "update.log")
    try fm.createDirectory(at: newApp, withIntermediateDirectories: true)
    let script = root.appending(path: "swap.sh")
    try UpdateSwap.script.write(to: script, atomically: true, encoding: .utf8)
    let p = Process()
    p.executableURL = URL(filePath: "/bin/sh")
    p.arguments = [script.path] + UpdateSwap.arguments(
        pid: 0x7fff_fff0, destination: missing.path, newApp: newApp.path,
        work: root.appending(path: "work").path, log: log.path, opener: "/usr/bin/true")
    try p.run()
    p.waitUntilExit()
    #expect(!fm.fileExists(atPath: missing.path))
    #expect(try String(contentsOf: log, encoding: .utf8).contains("update FAILED: could not move"))
}
