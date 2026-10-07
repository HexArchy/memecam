import CoreMediaIO
import Foundation

/// Identifiers shared with the camera extension (CameraExtension/Config.swift, scripts/build-app.sh).
enum VirtualCameraIDs {
    static let extensionBundleID = "com.hexarch.memecam.camera-extension"
    static let deviceUID = "com.hexarch.memecam.device"
    static let deviceName = "MemeCam"
}

/// Thin, synchronous wrappers over the CoreMediaIO C API. They talk to the CMIO server over IPC and
/// can take a few milliseconds, so call them off the main thread and never on the capture queue.
enum CMIO {
    static func address(_ selector: Int, scope: Int = kCMIOObjectPropertyScopeGlobal,
                        element: Int = kCMIOObjectPropertyElementMain) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(selector),
                                  mScope: CMIOObjectPropertyScope(scope),
                                  mElement: CMIOObjectPropertyElement(element))
    }

    static func objectIDs(of object: CMIOObjectID, _ selector: Int) -> [CMIOObjectID] {
        var addr = address(selector)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        let status = ids.withUnsafeMutableBytes { raw in
            CMIOObjectGetPropertyData(object, &addr, 0, nil, size, &used, raw.baseAddress!)
        }
        guard status == noErr else { return [] }
        return Array(ids.prefix(Int(used) / MemoryLayout<CMIOObjectID>.size))
    }

    static func string(of object: CMIOObjectID, _ selector: Int) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var used: UInt32 = 0
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            CMIOObjectGetPropertyData(object, &addr, 0, nil, UInt32(MemoryLayout<Unmanaged<CFString>?>.size),
                                      &used, ptr)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func uint32(of object: CMIOObjectID, _ selector: Int) -> UInt32? {
        var addr = address(selector)
        var value: UInt32 = 0
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(object, &addr, 0, nil, 4, &used, &value) == noErr else { return nil }
        return value
    }

    static var devices: [CMIOObjectID] {
        objectIDs(of: CMIOObjectID(kCMIOObjectSystemObject), kCMIOHardwarePropertyDevices)
    }

    /// The MemeCam device, matched by UID (stable) with the localized name as a fallback.
    static func findVirtualCamera() -> CMIOObjectID? {
        let all = devices
        if let dev = all.first(where: { string(of: $0, kCMIODevicePropertyDeviceUID) == VirtualCameraIDs.deviceUID }) {
            return dev
        }
        return all.first(where: { string(of: $0, kCMIOObjectPropertyName) == VirtualCameraIDs.deviceName })
    }

    /// The extension's sink stream. Seen from the app, the sink has direction 0 (measured on macOS 26.6).
    static func sinkStream(of device: CMIOObjectID) -> CMIOStreamID? {
        objectIDs(of: device, kCMIODevicePropertyStreams).first { uint32(of: $0, kCMIOStreamPropertyDirection) == 0 }
    }

    /// kCMIODevicePropertyDeviceIsRunningSomewhere: some process (any app, including MemeCam's own sink
    /// feed) has a stream of the device running. nil when the property can't be read.
    static func isRunningSomewhere(_ device: CMIOObjectID) -> Bool? {
        uint32(of: device, kCMIODevicePropertyDeviceIsRunningSomewhere).map { $0 != 0 }
    }

    /// Custom device property published by the camera extension ('mcsc', see CameraExtension/DeviceSource.swift):
    /// the number of apps reading the source stream. nil when the installed extension predates it.
    static func sourceClients(_ device: CMIOObjectID) -> Int? {
        var addr = address(0x6D63_7363) // 'mcsc'
        guard CMIOObjectHasProperty(device, &addr) else { return nil }
        return string(of: device, 0x6D63_7363).flatMap { Int($0) }
    }

    /// Calls `handler` on `queue` whenever the system device list changes. Returns a token for `removeListener`.
    static func addDevicesListener(queue: DispatchQueue, _ handler: @escaping @Sendable () -> Void) -> CMIOObjectPropertyListenerBlock? {
        var addr = address(kCMIOHardwarePropertyDevices)
        let block: CMIOObjectPropertyListenerBlock = { _, _ in handler() }
        let status = CMIOObjectAddPropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &addr, queue, block)
        return status == noErr ? block : nil
    }

    static func removeDevicesListener(_ block: @escaping CMIOObjectPropertyListenerBlock, queue: DispatchQueue) {
        var addr = address(kCMIOHardwarePropertyDevices)
        CMIOObjectRemovePropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &addr, queue, block)
    }
}
