import CoreMedia
import Foundation

/// Shared constants. Keep in sync with `VirtualCameraIDs` in the app (Sources/MemeCam/VirtualCamera).
enum Config {
    static let width: Int32 = 1280
    static let height: Int32 = 720
    static let fps: Int32 = 30
    static let frameDuration = CMTime(value: 1, timescale: fps)
    /// Device UID seen by CMIO clients (kCMIODevicePropertyDeviceUID). The app looks the device up by it.
    static let deviceUID = "com.hexarch.memecam.device"
    static let deviceName = "MemeCam"
    static let manufacturer = "hexarch"
    // Stable IDs so clients (Discord, Chrome) remember the selected camera across launches.
    static let deviceID = UUID(uuidString: "6B0C3C5A-1E6A-4D7B-9A55-2C1F0A0D0001")!
    static let sourceStreamID = UUID(uuidString: "6B0C3C5A-1E6A-4D7B-9A55-2C1F0A0D0002")!
    static let sinkStreamID = UUID(uuidString: "6B0C3C5A-1E6A-4D7B-9A55-2C1F0A0D0003")!
    /// App frames older than this are considered stale and the placeholder is shown instead.
    static let staleAfterNanos: UInt64 = 500_000_000
}

enum HostClock {
    static func nowNanos() -> UInt64 {
        let t = CMClockGetTime(CMClockGetHostTimeClock())
        return UInt64(max(0, t.seconds) * 1_000_000_000)
    }

    static func now() -> CMTime { CMClockGetTime(CMClockGetHostTimeClock()) }
}
