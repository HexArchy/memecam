import CoreMediaIO
import Foundation

/// The stream that camera clients (Discord, Telegram, FaceTime...) read from.
final class SourceStreamSource: NSObject, CMIOExtensionStreamSource, @unchecked Sendable {
    // Invariant: all stored properties are immutable after init except `stream`, set once by the owner.
    private let format: CMIOExtensionStreamFormat
    private unowned let owner: DeviceSource
    private(set) var stream: CMIOExtensionStream!

    init(format: CMIOExtensionStreamFormat, owner: DeviceSource) {
        self.format = format
        self.owner = owner
        super.init()
        stream = CMIOExtensionStream(localizedName: "MemeCam Video", streamID: Config.sourceStreamID,
                                     direction: .source, clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [format] }

    var availableProperties: Set<CMIOExtensionProperty> { [.streamActiveFormatIndex, .streamFrameDuration] }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws
        -> CMIOExtensionStreamProperties {
        let result = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { result.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) { result.frameDuration = Config.frameDuration }
        return result
    }

    // Single fixed format and frame rate: nothing to change.
    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { true }

    func startStream() throws { owner.sourceDidStart() }
    func stopStream() throws { owner.sourceDidStop() }
}

/// The stream the MemeCam app writes composited frames into (app-side direction 0).
final class SinkStreamSource: NSObject, CMIOExtensionStreamSource, @unchecked Sendable {
    private let format: CMIOExtensionStreamFormat
    private unowned let owner: DeviceSource
    private(set) var stream: CMIOExtensionStream!
    // Written by authorizedToStartStream and read by startStream; CMIO calls both on its client queue.
    private let pendingClient = NSLock()
    private var client: CMIOExtensionClient?

    init(format: CMIOExtensionStreamFormat, owner: DeviceSource) {
        self.format = format
        self.owner = owner
        super.init()
        stream = CMIOExtensionStream(localizedName: "MemeCam Sink", streamID: Config.sinkStreamID,
                                     direction: .sink, clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [format] }

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

    // Do not gate on client.signingID: it is nil for development-signed hosts (measured on macOS 26.6).
    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        pendingClient.withLock { self.client = client }
        return true
    }

    func startStream() throws {
        let client = pendingClient.withLock { self.client }
        guard let client else { throw CocoaError(.featureUnsupported) }
        owner.sinkDidStart(client: client)
    }

    func stopStream() throws { owner.sinkDidStop() }
}
