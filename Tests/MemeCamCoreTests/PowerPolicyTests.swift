import Foundation
import Testing
@testable import MemeCamCore

/// Events let through by `gate` for a 30 fps source with ±3 ms jitter over `seconds`.
private func fired(_ gate: inout RateGate, seconds: Double, fps: Double = 30) -> Int {
    var count = 0
    let frames = Int(seconds * fps)
    for i in 0..<frames {
        let jitter = Double((i * 7919) % 7 - 3) / 1000
        if gate.tryFire(at: 100 + Double(i) / fps + jitter) { count += 1 }
    }
    return count
}

/// `#expect` can't call mutating methods inline.
private func fire(_ gate: inout RateGate, _ t: TimeInterval) -> Bool { gate.tryFire(at: t) }

@Test func rateGateCapsA30FpsSource() {
    for hz in [15.0, 10, 8] {
        var gate = RateGate(hz: hz)
        let n = fired(&gate, seconds: 10)
        #expect(abs(Double(n) - hz * 10) <= 2, "\(hz) Hz gave \(n) events in 10 s")
    }
}

@Test func rateGateZeroBlocksAndResetFiresImmediately() {
    var gate = RateGate(hz: 0)
    #expect(fired(&gate, seconds: 2) == 0)
    gate.hz = 15
    #expect(fire(&gate, 200))
    #expect(!fire(&gate, 200.01))
    gate.reset()
    #expect(fire(&gate, 200.02))
}

@Test func rateGateDoesNotBurstAfterAPause() {
    var gate = RateGate(hz: 15)
    #expect(fire(&gate, 0))
    // Nothing for 5 s (Vision was busy / idle): one event, then the normal cadence.
    #expect(fire(&gate, 5))
    #expect(!fire(&gate, 5.034))
    #expect(fire(&gate, 5.067))
}

@Test func powerModeIdlesOnlyWhenNobodyWatches() {
    let idle = PowerMode.decide(windowVisible: false, consumerActive: false, thermal: .nominal, lowPowerMode: false)
    #expect(idle.idle && idle.visionHz == 0 && idle.note != nil)
    // Window closed, but Discord reads the virtual camera: full speed (the main use case).
    let call = PowerMode.decide(windowVisible: false, consumerActive: true, thermal: .nominal, lowPowerMode: false)
    #expect(!call.idle && call.visionHz == PowerMode.normalHz && call.note == nil)
    let window = PowerMode.decide(windowVisible: true, consumerActive: false, thermal: .fair, lowPowerMode: false)
    #expect(!window.idle && window.visionHz == PowerMode.normalHz)
}

@Test func powerModeSlowsDownWhenHotOrInLowPowerMode() {
    let lpm = PowerMode.decide(windowVisible: true, consumerActive: false, thermal: .nominal, lowPowerMode: true)
    #expect(lpm.visionHz == PowerMode.lowPowerHz && lpm.note != nil)
    for thermal in [ThermalLevel.serious, .critical] {
        let hot = PowerMode.decide(windowVisible: true, consumerActive: true, thermal: thermal, lowPowerMode: true)
        #expect(hot.visionHz == PowerMode.hotHz)
    }
    // Idle wins over everything: nothing runs.
    let idleHot = PowerMode.decide(windowVisible: false, consumerActive: false, thermal: .critical, lowPowerMode: true)
    #expect(idleHot.idle && idleHot.visionHz == 0)
}

@Test func missingPreferredCameraIsKeptAndFallsBack() {
    typealias D = CameraSelection.Device
    let mac = D(id: "facetime")
    let phone = D(id: "iphone")
    // iPhone in another room at launch: use the default, but don't forget the preference.
    #expect(CameraSelection.preferredIfAvailable("iphone", in: [mac]) == nil)
    #expect(CameraSelection.preferredIfAvailable("iphone", in: [mac, phone]) == "iphone")
    #expect(CameraSelection.preferredIfAvailable("iphone", in: [mac, D(id: "iphone", isSuspended: true)]) == nil)
    #expect(CameraSelection.preferredIfAvailable(nil, in: [mac, phone]) == nil)
    // Running on the fallback; the iPhone comes back: switch back to it.
    #expect(!CameraSelection.shouldSwitch(active: "facetime", preferred: "iphone", available: [mac]))
    #expect(CameraSelection.shouldSwitch(active: "facetime", preferred: "iphone", available: [mac, phone]))
    // The active camera was unplugged: switch (to the fallback).
    #expect(CameraSelection.shouldSwitch(active: "iphone", preferred: "iphone", available: [mac]))
    // "Default" preference and the active camera is still there: stay.
    #expect(!CameraSelection.shouldSwitch(active: "iphone", preferred: nil, available: [mac, phone]))
}
