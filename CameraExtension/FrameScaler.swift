import Accelerate
import CoreVideo
import Foundation

/// Aspect-fills BGRA frames into another size (centre crop + Lanczos scale, vImage on the CPU).
/// Only used when a camera client picked a format other than the one the app renders; matching frames
/// pass through untouched. Not thread-safe: confined to the device queue.
final class FrameScaler {
    private var pools: [OutputFormat: CVPixelBufferPool] = [:]
    private var tempBuffer: UnsafeMutableRawPointer?
    private var tempSize = 0

    deinit { tempBuffer?.deallocate() }

    /// A buffer of `format`'s size from a small per-size pool (IOSurface-backed, so it crosses to clients).
    func makeBuffer(_ format: OutputFormat) -> CVPixelBuffer? {
        if pools[format] == nil {
            let attrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: format.width,
                kCVPixelBufferHeightKey: format.height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ]
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, [kCVPixelBufferPoolMinimumBufferCountKey: 3] as CFDictionary,
                                    attrs as CFDictionary, &pool)
            pools[format] = pool
        }
        guard let pool = pools[format] else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        return buffer
    }

    /// `source` aspect-filled into a new buffer of `format`'s size; nil on failure.
    func scale(_ source: CVPixelBuffer, to format: OutputFormat) -> CVPixelBuffer? {
        guard let out = makeBuffer(format) else { return nil }
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(out, [])
        defer {
            CVPixelBufferUnlockBaseAddress(out, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        guard let srcBase = CVPixelBufferGetBaseAddress(source), let dstBase = CVPixelBufferGetBaseAddress(out)
        else { return nil }

        // Centre crop of the source with the target's aspect ratio.
        let sw = CVPixelBufferGetWidth(source), sh = CVPixelBufferGetHeight(source)
        let srcRowBytes = CVPixelBufferGetBytesPerRow(source)
        let targetAspect = Double(format.width) / Double(format.height)
        var cropW = sw, cropH = sh
        if Double(sw) / Double(sh) > targetAspect {
            cropW = min(sw, Int((Double(sh) * targetAspect).rounded()))
        } else {
            cropH = min(sh, Int((Double(sw) / targetAspect).rounded()))
        }
        let x = (sw - cropW) / 2, y = (sh - cropH) / 2
        var src = vImage_Buffer(data: srcBase.advanced(by: y * srcRowBytes + x * 4), height: vImagePixelCount(cropH),
                                width: vImagePixelCount(cropW), rowBytes: srcRowBytes)
        var dst = vImage_Buffer(data: dstBase, height: vImagePixelCount(format.height),
                                width: vImagePixelCount(format.width), rowBytes: CVPixelBufferGetBytesPerRow(out))

        let flags = vImage_Flags(kvImageHighQualityResampling)
        let needed = vImageScale_ARGB8888(&src, &dst, nil, flags | vImage_Flags(kvImageGetTempBufferSize))
        guard needed >= 0 else { return nil }
        if needed > tempSize {
            tempBuffer?.deallocate()
            tempBuffer = UnsafeMutableRawPointer.allocate(byteCount: needed, alignment: 64)
            tempSize = needed
        }
        guard vImageScale_ARGB8888(&src, &dst, tempBuffer, flags) == kvImageNoError else { return nil }
        return out
    }
}
