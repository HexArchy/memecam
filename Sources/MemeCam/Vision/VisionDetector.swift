import CoreGraphics
import CoreVideo
import Foundation
import MemeCamCore
import Vision

/// Runs face-landmark and hand-pose detection on camera frames.
///
/// Speed notes (vs. Python/MediaPipe meme apps that run ~15–25 FPS on CPU):
/// - One `VNImageRequestHandler` per frame executes both requests in a single pass,
///   sharing the image pre-processing; Vision schedules the models on the ANE/GPU.
/// - Request objects are created once and reused.
/// - Hand pose runs every other frame while no hand is visible, every frame otherwise.
/// - Called only from the capture queue, so no locking is needed.
final class VisionDetector: @unchecked Sendable {
    private let faceRequest: VNDetectFaceLandmarksRequest = {
        let r = VNDetectFaceLandmarksRequest()
        r.revision = VNDetectFaceLandmarksRequestRevision3
        r.constellation = .constellation76Points // explicit: brows/lips need the dense layout
        return r
    }()
    private let handRequest: VNDetectHumanHandPoseRequest = {
        let r = VNDetectHumanHandPoseRequest()
        r.maximumHandCount = 2
        return r
    }()

    private var frameIndex = 0
    private var handsVisible = false
    private var lastHands: [HandPose] = []

    var detectHands = true
    /// Minimum per-joint confidence; Vision reports low confidence for occluded joints.
    var jointConfidence: Float = 0.3

    func detect(_ pixelBuffer: CVPixelBuffer, timestamp: TimeInterval) -> FrameObservation {
        frameIndex &+= 1
        let width = Double(CVPixelBufferGetWidth(pixelBuffer))
        let height = Double(CVPixelBufferGetHeight(pixelBuffer))
        let aspect = width / height

        let runHands = detectHands && (handsVisible || frameIndex % 2 == 0)
        let requests: [VNRequest] = runHands ? [faceRequest, handRequest] : [faceRequest]
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        do {
            try handler.perform(requests)
        } catch {
            return FrameObservation(timestamp: timestamp, face: nil, hands: lastHands)
        }

        // Largest face only.
        let faceObs = (faceRequest.results ?? []).max {
            $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height
        }
        let face = faceObs.flatMap { Self.landmarks($0, imageSize: CGSize(width: width, height: height)) }

        if runHands {
            lastHands = (handRequest.results ?? []).compactMap { hand($0, aspect: aspect) }
            handsVisible = !lastHands.isEmpty
        } else if !detectHands {
            lastHands = []
        }
        return FrameObservation(timestamp: timestamp, face: face, hands: lastHands)
    }

    // MARK: - Conversion to aspect space (x in [0, w/h], y in [0, 1], y up)

    private static func landmarks(_ obs: VNFaceObservation, imageSize: CGSize) -> FaceLandmarks? {
        guard let lm = obs.landmarks else { return nil }
        let h = imageSize.height
        func pts(_ region: VNFaceLandmarkRegion2D?) -> [CGPoint] {
            guard let region else { return [] }
            return region.pointsInImage(imageSize: imageSize).map { CGPoint(x: $0.x / h, y: $0.y / h) }
        }
        let aspect = imageSize.width / h
        let bb = obs.boundingBox
        return FaceLandmarks(
            boundingBox: CGRect(x: bb.minX * aspect, y: bb.minY, width: bb.width * aspect, height: bb.height),
            leftEye: pts(lm.leftEye), rightEye: pts(lm.rightEye),
            leftBrow: pts(lm.leftEyebrow), rightBrow: pts(lm.rightEyebrow),
            outerLips: pts(lm.outerLips), innerLips: pts(lm.innerLips),
            roll: obs.roll?.doubleValue ?? 0,
            yaw: obs.yaw?.doubleValue ?? 0,
            pitch: obs.pitch?.doubleValue ?? 0
        )
    }

    private static let jointMap: [(VNHumanHandPoseObservation.JointName, HandJoint)] = [
        (.wrist, .wrist),
        (.thumbCMC, .thumbCMC), (.thumbMP, .thumbMP), (.thumbIP, .thumbIP), (.thumbTip, .thumbTip),
        (.indexMCP, .indexMCP), (.indexPIP, .indexPIP), (.indexDIP, .indexDIP), (.indexTip, .indexTip),
        (.middleMCP, .middleMCP), (.middlePIP, .middlePIP), (.middleDIP, .middleDIP), (.middleTip, .middleTip),
        (.ringMCP, .ringMCP), (.ringPIP, .ringPIP), (.ringDIP, .ringDIP), (.ringTip, .ringTip),
        (.littleMCP, .littleMCP), (.littlePIP, .littlePIP), (.littleDIP, .littleDIP), (.littleTip, .littleTip),
    ]

    private func hand(_ obs: VNHumanHandPoseObservation, aspect: Double) -> HandPose? {
        guard let points = try? obs.recognizedPoints(.all) else { return nil }
        var joints: [HandJoint: CGPoint] = [:]
        joints.reserveCapacity(21)
        for (vn, j) in Self.jointMap {
            if let p = points[vn], p.confidence >= jointConfidence {
                joints[j] = CGPoint(x: p.location.x * aspect, y: p.location.y)
            }
        }
        guard joints.count >= 12 else { return nil }
        return HandPose(joints: joints, confidence: Double(obs.confidence))
    }
}
