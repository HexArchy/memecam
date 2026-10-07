import Foundation
import Testing
@testable import MemeCamCore

/// `#expect` can't call mutating methods inline.
private func feed(_ t: inout AwayTracker, nobody: Bool, face: Bool, at time: TimeInterval) -> Bool {
    t.update(nobodyHere: nobody, faceDetected: face, at: time)
}

@Test func awayStartsAfterTheDelayOfNobodyHere() {
    var t = AwayTracker(delay: 30)
    #expect(!feed(&t, nobody: true, face: false, at: 100))
    #expect(!feed(&t, nobody: true, face: false, at: 129.9))
    #expect(!t.isAway)
    #expect(feed(&t, nobody: true, face: false, at: 130))
    #expect(t.isAway)
    // Staying away reports no further change.
    #expect(!feed(&t, nobody: true, face: false, at: 140))
}

@Test func awayTimerRestartsWhenSomebodyShowsUpEarly() {
    var t = AwayTracker(delay: 10)
    _ = feed(&t, nobody: true, face: false, at: 0)
    _ = feed(&t, nobody: false, face: true, at: 8) // back before the delay
    _ = feed(&t, nobody: true, face: false, at: 9)
    #expect(!feed(&t, nobody: true, face: false, at: 18))
    #expect(feed(&t, nobody: true, face: false, at: 19))
}

@Test func awayEndsAfterConfirmedFaces() {
    var t = AwayTracker(delay: 10, returnConfirmations: 2)
    _ = feed(&t, nobody: true, face: false, at: 0)
    _ = feed(&t, nobody: true, face: false, at: 10)
    #expect(t.isAway)
    // One stray detection is not enough, and a miss resets the count.
    #expect(!feed(&t, nobody: true, face: true, at: 11))
    #expect(!feed(&t, nobody: true, face: false, at: 11.25))
    #expect(!feed(&t, nobody: true, face: true, at: 11.5))
    #expect(feed(&t, nobody: true, face: true, at: 11.75))
    #expect(!t.isAway)
    // The stabilizer still says "nobody here" for a moment: the timer starts over, no instant re-entry.
    #expect(!feed(&t, nobody: true, face: false, at: 12))
    #expect(!t.isAway)
}

@Test func awayOffNeverTriggersAndSwitchingOffLeavesAway() {
    var off = AwayTracker(delay: AwayDelay.off.seconds)
    for s in 0..<200 { _ = feed(&off, nobody: true, face: false, at: Double(s)) }
    #expect(!off.isAway)

    var t = AwayTracker(delay: 10)
    _ = feed(&t, nobody: true, face: false, at: 0)
    _ = feed(&t, nobody: true, face: false, at: 10)
    #expect(t.isAway)
    t.delay = nil
    #expect(!t.isAway)
}

@Test func awayResetAndVisionRate() {
    var t = AwayTracker(delay: 10)
    #expect(t.visionHz(power: 15) == 15)
    _ = feed(&t, nobody: true, face: false, at: 0)
    _ = feed(&t, nobody: true, face: false, at: 10)
    #expect(t.visionHz(power: 15) == AwayTracker.visionHz)
    #expect(t.visionHz(power: 0) == 0) // idle stays idle
    let first = t.reset(), second = t.reset()
    #expect(first)
    #expect(!second)
    #expect(t.visionHz(power: 8) == 8)
}

@Test func awayDelaySettings() {
    #expect(AwayDelay.default == .thirtySeconds)
    #expect(AwayDelay.off.seconds == nil)
    #expect(AwayDelay.oneMinute.seconds == 60)
    #expect(AwayDelay(rawValue: 10) == .tenSeconds)
}

@Test func menuBarPresence() {
    #expect(CameraPresence.decide(cameraOn: false, memesPaused: true, away: true) == .off)
    #expect(CameraPresence.decide(cameraOn: true, memesPaused: false, away: false) == .live)
    #expect(CameraPresence.decide(cameraOn: true, memesPaused: true, away: false) == .paused)
    #expect(CameraPresence.decide(cameraOn: true, memesPaused: false, away: true) == .away)
}

// MARK: Virtual camera checklist

private func check(_ ext: VirtualCameraChecklist.ExtensionStatus = .enabled, device: Bool = true, fps: Double = 0,
                   running: Bool = false, test: Bool = false, clients: Int? = 0) -> [VirtualCameraChecklist.Item] {
    VirtualCameraChecklist.evaluate(.init(extensionStatus: ext, deviceVisible: device, fps: fps,
                                          cameraRunning: running, testPattern: test, clients: clients))
}

@Test func checklistAllGreenWhileAnAppWatches() {
    let items = check(fps: 30, running: true, clients: 2)
    #expect(items.map(\.kind) == VirtualCameraChecklist.Kind.allCases)
    #expect(items.allSatisfy { $0.status == .ok && $0.fix == nil })
}

@Test func checklistOffersInstallThenSettings() {
    let fresh = check(.notInstalled, device: false, clients: nil)
    #expect(fresh[0] == .init(.extensionEnabled, .failed, fix: .install))
    #expect(fresh.dropFirst().allSatisfy { $0.status == .pending && $0.fix == nil })

    let approval = check(.awaitingApproval, device: false, clients: nil)
    #expect(approval[0] == .init(.extensionEnabled, .warning, fix: .openSettings))

    let disabled = check(.enabled, device: false, clients: nil)
    #expect(disabled[0].status == .ok)
    #expect(disabled[1] == .init(.deviceVisible, .warning, fix: .relaunch))

    #expect(check(.failed, device: false, clients: nil)[0].fix == .retry)
}

@Test func checklistVisibleDeviceProvesTheExtension() {
    // sysextd hasn't answered (or failed), but the device is there.
    #expect(check(.unknown, fps: 30, running: true)[0].status == .ok)
    #expect(check(.failed, fps: 30, running: true)[0].status == .ok)
}

@Test func checklistFramesNeedTheCameraOrTestPattern() {
    #expect(check(running: false)[2] == .init(.framesFlowing, .warning, fix: .startCamera))
    #expect(check(running: true)[2] == .init(.framesFlowing, .pending))
    #expect(check(test: true)[2] == .init(.framesFlowing, .pending))
    #expect(check(fps: 14.5, test: true)[2].status == .ok)
    #expect(check(fps: 0.5, running: true)[2].status == .pending)
}

@Test func checklistAppsRow() {
    #expect(check(clients: 0)[3].status == .info)
    #expect(check(clients: 1)[3].status == .ok)
    #expect(check(clients: nil)[3].status == .pending)
    #expect(check(device: false, clients: 3)[3].status == .pending)
}
