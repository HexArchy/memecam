@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo

/// Anything that consumes composited output frames (on-screen preview, virtual camera).
protocol FrameSink: AnyObject, Sendable {
    func send(_ pixelBuffer: CVPixelBuffer, time: CMTime)
}

extension CMSampleBuffer {
    static func make(_ pixelBuffer: CVPixelBuffer, time: CMTime, fps: Int32 = 30) -> CMSampleBuffer? {
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: nil, imageBuffer: pixelBuffer, formatDescriptionOut: &format) == noErr,
            let format else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: fps),
                                        presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil, imageBuffer: pixelBuffer, formatDescription: format,
            sampleTiming: &timing, sampleBufferOut: &sample)
        return sample
    }
}

/// On-screen preview. AVSampleBufferDisplayLayer displays IOSurface buffers with zero copies.
final class PreviewSink: FrameSink, @unchecked Sendable {
    let layer: AVSampleBufferDisplayLayer = {
        let l = AVSampleBufferDisplayLayer()
        l.videoGravity = .resizeAspect
        l.backgroundColor = .clear
        return l
    }()

    func send(_ pixelBuffer: CVPixelBuffer, time: CMTime) {
        guard let sample = CMSampleBuffer.make(pixelBuffer, time: time) else { return }
        // Display immediately; we already pace frames ourselves.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        let renderer = layer.sampleBufferRenderer
        if renderer.status == .failed { renderer.flush() }
        renderer.enqueue(sample)
    }
}
