import Carbon.HIToolbox
import os

/// A system-wide key combination.
struct HotKey: Sendable {
    let keyCode: UInt32
    /// Carbon modifier mask (`controlKey`, `optionKey`, …).
    let modifiers: UInt32

    /// ⌃⌥P — pause / resume memes, even while Discord or Zoom is frontmost.
    static let pauseMemes = HotKey(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(controlKey | optionKey))
}

/// System-wide hotkeys through Carbon `RegisterEventHotKey`: they fire while other apps are
/// frontmost and need no Accessibility permission. Hotkey events arrive on the main run loop.
/// Lives as long as the app (owned by `AppModel`), so registrations are never torn down.
@MainActor
final class GlobalHotKeys {
    private var actions: [UInt32: @MainActor () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private let log = Logger(subsystem: "com.hexarch.memecam", category: "hotkeys")

    /// Registers `hotKey`; returns false if another app already owns the combination.
    @discardableResult
    func register(_ hotKey: HotKey, action: @escaping @MainActor () -> Void) -> Bool {
        installHandlerIfNeeded()
        let id = UInt32(actions.count + 1)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(hotKey.keyCode, hotKey.modifiers,
                                         EventHotKeyID(signature: Self.signature, id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            log.error("RegisterEventHotKey(\(hotKey.keyCode), \(hotKey.modifiers)) failed: \(status)")
            return false
        }
        log.info("Registered global hotkey \(hotKey.keyCode) with modifiers \(hotKey.modifiers)")
        refs.append(ref)
        actions[id] = action
        return true
    }

    private func fire(_ id: UInt32) { actions[id]?() }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr, hotKeyID.signature == GlobalHotKeys.signature, let userData else {
                return OSStatus(eventNotHandledErr)
            }
            let id = hotKeyID.id
            MainActor.assumeIsolated {
                Unmanaged<GlobalHotKeys>.fromOpaque(userData).takeUnretainedValue().fire(id)
            }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    /// 'MmCm'
    private nonisolated static let signature: OSType = 0x4D6D_434D
}
