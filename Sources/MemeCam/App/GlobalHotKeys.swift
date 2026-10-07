import Carbon.HIToolbox
import os

/// A system-wide key combination.
struct HotKey: Sendable {
    let keyCode: UInt32
    /// Carbon modifier mask (`controlKey`, `optionKey`, …).
    let modifiers: UInt32

    /// ⌃⌥P — pause / resume memes, even while Discord or Zoom is frontmost.
    static let pauseMemes = HotKey(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(controlKey | optionKey))

    /// ⌃⌥0 — show / hide the floating trigger palette.
    static let togglePalette = HotKey(keyCode: UInt32(kVK_ANSI_0), modifiers: UInt32(controlKey | optionKey))

    /// ⌃⌥1 … ⌃⌥9 — fire trigger slot `index` (0-based). Digit key codes are not contiguous.
    static func triggerSlot(_ index: Int) -> HotKey {
        let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                      kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        return HotKey(keyCode: UInt32(digits[index]), modifiers: UInt32(controlKey | optionKey))
    }
}

/// System-wide hotkeys through Carbon `RegisterEventHotKey`: they fire while other apps are
/// frontmost and need no Accessibility permission. Hotkey events arrive on the main run loop.
/// Lives as long as the app (owned by `AppModel`); the event handler is never removed, single
/// hotkeys can be (`unregister`).
@MainActor
final class GlobalHotKeys {
    /// Identifies one registration, for `unregister`.
    struct Token: Hashable, Sendable { fileprivate let id: UInt32 }

    private var registrations: [UInt32: (ref: EventHotKeyRef, action: @MainActor () -> Void)] = [:]
    private var nextID: UInt32 = 1
    private var handler: EventHandlerRef?
    private let log = Logger(subsystem: "com.hexarch.memecam", category: "hotkeys")

    /// Registers `hotKey`; returns nil if another app already owns the combination.
    @discardableResult
    func register(_ hotKey: HotKey, action: @escaping @MainActor () -> Void) -> Token? {
        installHandlerIfNeeded()
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(hotKey.keyCode, hotKey.modifiers,
                                         EventHotKeyID(signature: Self.signature, id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            log.error("RegisterEventHotKey(\(hotKey.keyCode), \(hotKey.modifiers)) failed: \(status)")
            return nil
        }
        log.info("Registered global hotkey \(hotKey.keyCode) with modifiers \(hotKey.modifiers)")
        registrations[id] = (ref, action)
        return Token(id: id)
    }

    /// Releases a combination registered with `register` (no-op for an unknown token).
    func unregister(_ token: Token) {
        guard let entry = registrations.removeValue(forKey: token.id) else { return }
        let status = UnregisterEventHotKey(entry.ref)
        if status != noErr { log.error("UnregisterEventHotKey failed: \(status)") }
        log.info("Unregistered global hotkey \(token.id)")
    }

    private func fire(_ id: UInt32) { registrations[id]?.action() }

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
