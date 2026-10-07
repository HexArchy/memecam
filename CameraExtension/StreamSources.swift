import CoreMediaIO
import Foundation
import os
import Security

/// The stream that camera clients (Discord, Telegram, FaceTime...) read from.
final class SourceStreamSource: NSObject, CMIOExtensionStreamSource, @unchecked Sendable {
    // Invariant: all stored properties are immutable after init except `stream`, set once by the owner.
    let formats: [CMIOExtensionStreamFormat]
    private unowned let owner: DeviceSource
    private(set) var stream: CMIOExtensionStream!

    init(formats: [CMIOExtensionStreamFormat], owner: DeviceSource) {
        self.formats = formats
        self.owner = owner
        super.init()
        stream = CMIOExtensionStream(localizedName: "MemeCam Video", streamID: Config.sourceStreamID,
                                     direction: .source, clockType: .hostTime, source: self)
    }

    var availableProperties: Set<CMIOExtensionProperty> { [.streamActiveFormatIndex, .streamFrameDuration] }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws
        -> CMIOExtensionStreamProperties {
        let result = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { result.activeFormatIndex = owner.activeFormatIndex }
        if properties.contains(.streamFrameDuration) { result.frameDuration = Config.frameDuration }
        return result
    }

    // A client picks a size/aspect; the frame rate is fixed.
    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let index = streamProperties.activeFormatIndex { owner.clientSelectedFormat(index: index) }
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { true }

    func startStream() throws { owner.sourceDidStart() }
    func stopStream() throws { owner.sourceDidStop() }
}

/// The stream the MemeCam app writes composited frames into (app-side direction 0).
final class SinkStreamSource: NSObject, CMIOExtensionStreamSource, @unchecked Sendable {
    let formats: [CMIOExtensionStreamFormat]
    private unowned let owner: DeviceSource
    private(set) var stream: CMIOExtensionStream!
    // Written by authorizedToStartStream and read by startStream; CMIO calls both on its client queue.
    private let pendingClient = NSLock()
    private var client: CMIOExtensionClient?

    init(formats: [CMIOExtensionStreamFormat], owner: DeviceSource) {
        self.formats = formats
        self.owner = owner
        super.init()
        stream = CMIOExtensionStream(localizedName: "MemeCam Sink", streamID: Config.sinkStreamID,
                                     direction: .sink, clockType: .hostTime, source: self)
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration, .streamSinkBufferQueueSize,
         .streamSinkBuffersRequiredForStartup, .streamSinkBufferUnderrunCount, .streamSinkEndOfData]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws
        -> CMIOExtensionStreamProperties {
        let result = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { result.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) { result.frameDuration = Config.frameDuration }
        if properties.contains(.streamSinkBufferQueueSize) { result.sinkBufferQueueSize = 4 }
        if properties.contains(.streamSinkBuffersRequiredForStartup) { result.sinkBuffersRequiredForStartup = 1 }
        if properties.contains(.streamSinkBufferUnderrunCount) { result.sinkBufferUnderrunCount = 0 }
        if properties.contains(.streamSinkEndOfData) { result.sinkEndOfData = 0 }
        return result
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}

    /// Only the MemeCam app may feed the camera, so another local process can't inject video into a call.
    /// `client.signingID`, when present, must be the app's identifier. It is nil for development-signed
    /// hosts (measured on macOS 26.6): then the client is allowed, so MemeCam's own feed never breaks, and
    /// logged together with a by-pid code check (diagnostic only: the pid can be reused, and dev builds
    /// signed ad hoc or run with `swift run` would fail it).
    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        let signingID = client.signingID, pid = client.pid
        // Measured on macOS 26.6: development hosts report nil, Developer ID (release) hosts report the
        // literal "unknown". Only a real identifier can be trusted as-is; otherwise verify the process'
        // code signature directly.
        if let signingID, signingID != "unknown" {
            guard SinkClientPolicy.isAllowed(signingID: signingID, team: SinkClientPolicy.ownTeam) else {
                Self.log.error("sink client rejected: signingID=\(signingID, privacy: .public) pid=\(pid)")
                return false
            }
            Self.log.notice("sink client allowed: signingID=\(signingID, privacy: .public) pid=\(pid)")
        } else {
            switch SinkClientPolicy.checkCode(pid: pid) {
            case .valid:
                Self.log.notice("sink client allowed by code signature, pid=\(pid)")
            case .rejected:
                Self.log.error("sink client rejected by code signature: signingID=\(signingID ?? "nil", privacy: .public) pid=\(pid)")
                return false
            case .unknown(let status):
                // Can't verify (e.g. unsigned dev build): keep the camera working, but leave a trace.
                Self.log.notice("sink client allowed unverified (\(status)): signingID=\(signingID ?? "nil", privacy: .public) pid=\(pid)")
            }
        }
        pendingClient.withLock { self.client = client }
        return true
    }

    private static let log = Logger(subsystem: "com.hexarch.memecam.camera-extension", category: "sink")

    func startStream() throws {
        let client = pendingClient.withLock { self.client }
        guard let client else { throw CocoaError(.featureUnsupported) }
        owner.sinkDidStart(client: client)
    }

    func stopStream() throws { owner.sinkDidStop() }
}

/// Who may write into the sink stream: the MemeCam app, signed by the same team as this extension.
enum SinkClientPolicy {
    static let appSigningID = "com.hexarch.memecam"

    /// This extension's Team ID (nil for unsigned builds, which then skip the code check).
    static let ownTeam: String? = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
            == errSecSuccess else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }()

    /// nil signingID is allowed (development hosts report none). Otherwise it must be the app's identifier,
    /// optionally in the "<TEAMID>.<bundle id>" form, and then only with this extension's team.
    static func isAllowed(signingID: String?, team: String?) -> Bool {
        guard let signingID else { return true }
        if signingID == appSigningID { return true }
        guard let team else { return false }
        return signingID == "\(team).\(appSigningID)"
    }

    enum CodeCheck { case valid, rejected, unknown(OSStatus) }

    /// Validates the running client against "MemeCam, Apple-anchored, signed by our team". Used for logging.
    static func checkCode(pid: pid_t) -> CodeCheck {
        guard let team = ownTeam else { return .unknown(errSecCSUnsigned) }
        var guest: SecCode?
        let attrs = [kSecGuestAttributePid: pid] as CFDictionary
        let found = SecCodeCopyGuestWithAttributes(nil, attrs, [], &guest)
        guard found == errSecSuccess, let guest else { return .unknown(found) }
        var requirement: SecRequirement?
        let text = "anchor apple generic and identifier \"\(appSigningID)\" and certificate leaf[subject.OU] = \"\(team)\""
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else {
            return .unknown(errSecCSReqInvalid)
        }
        let status = SecCodeCheckValidity(guest, [], requirement)
        switch status {
        case errSecSuccess: return .valid
        case errSecCSReqFailed: return .rejected
        default: return .unknown(status)
        }
    }
}
