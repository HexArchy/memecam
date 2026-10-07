#if DEBUG
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import MemeCamCore

/// Dev tool: `MEMECAM_FACE_SELFTEST=photo.jpg swift run MemeCam` runs Vision + the learned face models on a
/// photo exactly like on camera frames, prints the strongest signals and the reaction, and exits.
enum FaceSignalsSelfTest {
    static func runIfRequested() {
        guard let paths = ProcessInfo.processInfo.environment["MEMECAM_FACE_SELFTEST"] else { return }
        let detector = VisionDetector()
        Thread.sleep(forTimeInterval: 3) // models load in the background
        for path in paths.split(separator: ",").map(String.init) {
            guard let src = CGImageSourceCreateWithURL(URL(filePath: path) as CFURL, nil),
                  let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { print(path, "unreadable"); continue }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, cg.width, cg.height, kCVPixelFormatType_32BGRA,
                                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
            guard let buffer else { continue }
            CIContext().render(CIImage(cgImage: cg), to: buffer)
            var obs = detector.detect(buffer, timestamp: 0, detectHands: false)
            let t0 = CFAbsoluteTimeGetCurrent()
            for i in 1...20 { obs = detector.detect(buffer, timestamp: Double(i) / 15, detectHands: false) }
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000 / 20
            print("== \(path)  (\(String(format: "%.1f", ms)) ms per frame incl. Vision)")
            if let b = obs.signals?.blendshapes {
                let top = b.enumerated().sorted { $0.element > $1.element }.prefix(8)
                print("  blendshapes:", top.map { "\(Blendshape(rawValue: $0.offset)!)=\(String(format: "%.2f", $0.element))" }.joined(separator: " "))
            } else { print("  blendshapes: none") }
            if let e = obs.signals?.emotions {
                print("  emotions:", e.enumerated().map { "\(Emotion(rawValue: $0.offset)!)=\(String(format: "%.2f", $0.element))" }.joined(separator: " "))
            } else { print("  emotions: none") }
            var c = ReactionClassifier()
            var rules = ReactionClassifier()
            var plain = obs
            plain.signals = nil
            for i in 0..<20 {
                obs.timestamp = Double(i) / 15
                plain.timestamp = obs.timestamp
                _ = c.classify(obs)
                _ = rules.classify(plain)
            }
            print("  reaction with models:", c.classify(obs).reaction, " rules only:", rules.classify(plain).reaction)
        }
        exit(0)
    }
}
#endif
