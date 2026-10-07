import CoreImage
import CoreML
import CoreVideo
import Foundation
import MemeCamCore
import os

/// Runs the learned face models on the face Vision found: MediaPipe Face Mesh V2 → Blendshapes V2
/// (52 expression coefficients) and HSEmotion (8 expression probabilities). About 1.8 ms per frame on M1
/// (ANE), so they run on every Vision frame.
///
/// Crops follow the models' training: an upright square around the Vision face box, rotated by the face
/// roll — ×1.5 for Face Mesh (25% margin per side), ×1.0 for HSEmotion (tight detector box).
/// Models load in the background; until then (or if they are missing) `signals` returns nil and the rules
/// decide alone.
///
/// Concurrency: `signals` is only called on the pipeline's serial vision queue; models are published once
/// through `loaded`.
final class FaceSignalsDetector: @unchecked Sendable {
    // MLModel is thread-safe for predictions; it is published once and never mutated.
    private struct Models: @unchecked Sendable {
        let mesh: MLModel
        let blendshapes: MLModel
        let emotion: MLModel
        let indices: [Int]
    }

    private let loaded = OSAllocatedUnfairLock<Models?>(initialState: nil)
    private let context = CIContext(options: [.cacheIntermediates: false, .name: "MemeCam face crops"])
    private var meshPool: CVPixelBufferPool?
    private var emotionPool: CVPixelBufferPool?
    private let log = Logger(subsystem: "com.hexarch.memecam", category: "face-models")

    static let meshSize = 256
    static let emotionSize = 224

    init() {
        DispatchQueue.global(qos: .utility).async { [self] in
            let t0 = CFAbsoluteTimeGetCurrent()
            guard let models = Self.load() else {
                log.notice("face models not found; expressions use the rules only")
                return
            }
            loaded.withLock { $0 = models }
            log.info("face models loaded in \(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)) ms")
        }
    }

    private static func modelsDirectory() -> URL? {
        [Bundle.main.resourceURL?.appending(path: "Models"),
         URL(filePath: FileManager.default.currentDirectoryPath).appending(path: "Resources/Models")]
            .compactMap { $0 }
            .first { FileManager.default.fileExists(atPath: $0.appending(path: "FaceMesh.mlmodelc").path) }
    }

    private static func load() -> Models? {
        guard let dir = modelsDirectory(),
              let data = try? Data(contentsOf: dir.appending(path: "blendshape-indices.json")),
              let indices = try? JSONDecoder().decode([Int].self, from: data), indices.count == 146 else { return nil }
        func model(_ name: String, _ units: MLComputeUnits) -> MLModel? {
            let config = MLModelConfiguration()
            config.computeUnits = units
            return try? MLModel(contentsOf: dir.appending(path: "\(name).mlmodelc"), configuration: config)
        }
        // Face Mesh drifts ~1 px on the CPU in fp16; the fp32 blendshape model is fastest on the CPU.
        guard let mesh = model("FaceMesh", .cpuAndNeuralEngine),
              let blend = model("FaceBlendshapes", .cpuOnly),
              let emotion = model("HSEmotion", .cpuAndNeuralEngine) else { return nil }
        return Models(mesh: mesh, blendshapes: blend, emotion: emotion, indices: indices)
    }

    /// Signals for `face` in `frame` (nil while loading, for a turned-away face, or when Face Mesh sees no face).
    func signals(_ frame: CVPixelBuffer, face: FaceLandmarks) -> FaceSignals? {
        guard let m = loaded.withLock({ $0 }), abs(face.yaw) < 0.9, abs(face.pitch) < 0.9 else { return nil }
        let image = CIImage(cvPixelBuffer: frame)
        let h = Double(CVPixelBufferGetHeight(frame))
        // FaceLandmarks boxes are in aspect space (x in [0, w/h], y in [0, 1], y up): × height = pixels.
        let box = face.boundingBox
        let center = CGPoint(x: box.midX * h, y: box.midY * h)
        let side = max(box.width, box.height) * h

        var out = FaceSignals()
        if let crop = render(image, center: center, side: side * 1.5, angle: face.roll, size: Self.meshSize,
                             pool: &meshPool),
           let points = landmarks(m.mesh, crop: crop) {
            out.blendshapes = blendshapes(m, points: points)
        }
        if let crop = render(image, center: center, side: side, angle: face.roll, size: Self.emotionSize,
                             pool: &emotionPool) {
            out.emotions = emotions(m.emotion, crop: crop)
        }
        return out.blendshapes == nil && out.emotions == nil ? nil : out
    }

    // MARK: - Models

    /// Face Mesh x, y (crop pixels, origin top-left) of all 478 points, or nil when it sees no face.
    private func landmarks(_ model: MLModel, crop: CVPixelBuffer) -> [Float]? {
        guard let input = try? MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: crop)]),
              let result = try? model.prediction(from: input),
              let presence = result.featureValue(for: "presence")?.multiArrayValue,
              let points = result.featureValue(for: "landmarks")?.multiArrayValue,
              presence.count > 0, points.count >= 478 * 3 else { return nil }
        guard 1 / (1 + exp(-presence[0].doubleValue)) >= 0.5 else { return nil }
        return Self.floats(points)
    }

    private func blendshapes(_ m: Models, points: [Float]) -> [Float]? {
        guard let input = try? MLMultiArray(shape: [1, 146, 2], dataType: .float32) else { return nil }
        let p = input.dataPointer.bindMemory(to: Float.self, capacity: 292)
        for (i, idx) in m.indices.enumerated() {
            p[i * 2] = points[idx * 3]
            p[i * 2 + 1] = points[idx * 3 + 1]
        }
        guard let provider = try? MLDictionaryFeatureProvider(dictionary: ["points": MLFeatureValue(multiArray: input)]),
              let result = try? m.blendshapes.prediction(from: provider),
              let out = result.featureValue(for: "blendshapes")?.multiArrayValue, out.count == 52 else { return nil }
        return Self.floats(out)
    }

    private func emotions(_ model: MLModel, crop: CVPixelBuffer) -> [Float]? {
        guard let input = try? MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: crop)]),
              let result = try? model.prediction(from: input),
              let logits = result.featureValue(for: "logits")?.multiArrayValue, logits.count == 8 else { return nil }
        let z = Self.floats(logits)
        let mx = z.max() ?? 0
        let e = z.map { exp($0 - mx) }
        let sum = e.reduce(0, +)
        return e.map { $0 / sum }
    }

    private static func floats(_ a: MLMultiArray) -> [Float] {
        (0..<a.count).map { a[$0].floatValue }
    }

    // MARK: - Crops

    /// Upright square crop: `side` px around `center` (y-up image pixels), rotated by -`angle`, scaled to
    /// `size`², into a 32BGRA buffer (what Core ML image inputs take).
    private func render(_ image: CIImage, center: CGPoint, side: Double, angle: Double, size: Int,
                        pool: inout CVPixelBufferPool?) -> CVPixelBuffer? {
        guard side > 1 else { return nil }
        if pool == nil {
            let attrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: size, kCVPixelBufferHeightKey: size,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ]
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { return nil }
        let k = Double(size) / side
        // crop = k · R(−angle) · (p − centre) + size/2, all y-up; outside the frame stays black.
        let t = CGAffineTransform(translationX: -center.x, y: -center.y)
            .concatenating(CGAffineTransform(rotationAngle: -angle))
            .concatenating(CGAffineTransform(scaleX: k, y: k))
            .concatenating(CGAffineTransform(translationX: Double(size) / 2, y: Double(size) / 2))
        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        let crop = image.transformed(by: t)
            .composited(over: CIImage(color: .black).cropped(to: rect))
        context.render(crop, to: buffer, bounds: rect, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return buffer
    }
}
