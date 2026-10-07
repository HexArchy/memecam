import CoreGraphics
import CoreVideo
import Foundation
import MemeCamCore
import Vision

/// Runs face-landmark and hand-pose detection on camera frames.
///
/// Speed notes (vs. Python/MediaPipe meme apps that run ~15–25 FPS on CPU):
/// - The face is detected once: face rectangles (which also carry yaw/pitch) run first, together with
///   hand pose, and the largest face is fed into the landmarks request via `inputFaceObservations`,
///   so landmarks skip their own detection pass. No face: landmarks don't run at all.
/// - One `VNImageRequestHandler` per frame, shared by both passes (image pre-processing is cached);
///   Vision schedules the models on the ANE/GPU. Request objects are created once and reused.
/// - Hand pose runs every other call while no hand is visible, every call otherwise.
/// - The caller rate-limits (MemePipeline: ~15 Hz, lower in Low Power Mode / when hot).
///
/// Concurrency invariant (why `@unchecked Sendable` is sound): `detect` is only called on the
/// pipeline's serial `visionQueue`, one job at a time, so the requests and the cadence state below are
/// confined to that queue. Settings arrive as arguments instead of shared properties.
final class VisionDetector: @unchecked Sendable {
    private let faceRequest: VNDetectFaceLandmarksRequest = {
        let r = VNDetectFaceLandmarksRequest()
        r.revision = VNDetectFaceLandmarksRequestRevision3
        r.constellation = .constellation76Points // explicit: brows/lips need the dense layout
        return r
    }()
    /// Landmark observations don't carry yaw/pitch; rectangles revision 3 does.
    private let poseRequest: VNDetectFaceRectanglesRequest = {
        let r = VNDetectFaceRectanglesRequest()
        r.revision = VNDetectFaceRectanglesRequestRevision3
        return r
    }()
    private let handRequest: VNDetectHumanHandPoseRequest = {
        let r = VNDetectHumanHandPoseRequest()
        r.maximumHandCount = 2
        return r
    }()

    /// Learned expression models on top of the landmarks (see `FaceSignalFusion`).
    private let faceSignals = FaceSignalsDetector()

    private var frameIndex = 0
    private var handsVisible = false
    private var lastHands: [HandPose] = []

    /// Minimum per-joint confidence; Vision reports low confidence for occluded joints.
    private let jointConfidence: Float = 0.15

    func detect(_ pixelBuffer: CVPixelBuffer, timestamp: TimeInterval, detectHands: Bool) -> FrameObservation {
        frameIndex &+= 1
        let width = Double(CVPixelBufferGetWidth(pixelBuffer))
        let height = Double(CVPixelBufferGetHeight(pixelBuffer))
        let aspect = width / height

        let runHands = detectHands && (handsVisible || frameIndex % 2 == 0)
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        do {
            try handler.perform(runHands ? [poseRequest, handRequest] : [poseRequest])
        } catch {
            return FrameObservation(timestamp: timestamp, face: nil, hands: lastHands)
        }

        // Largest face only. Rectangles revision 3 carries yaw/pitch, which landmarks don't.
        let pose = (poseRequest.results ?? []).max {
            $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height
        }
        var face: FaceLandmarks?
        if let pose {
            faceRequest.inputFaceObservations = [pose]
            if (try? handler.perform([faceRequest])) != nil, let obs = faceRequest.results?.first,
               var f = Self.landmarks(obs, imageSize: CGSize(width: width, height: height)) {
                if let yaw = pose.yaw?.doubleValue { f.yaw = yaw }
                if let pitch = pose.pitch?.doubleValue { f.pitch = pitch }
                face = f
            }
        }

        if runHands {
            lastHands = (handRequest.results ?? []).compactMap { hand($0, aspect: aspect) }
            handsVisible = !lastHands.isEmpty
        } else if !detectHands {
            lastHands = []
        }
        let signals = face.flatMap { faceSignals.signals(pixelBuffer, face: $0) }
        return FrameObservation(timestamp: timestamp, face: face, hands: lastHands, signals: signals)
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
        // Wrist may be out of frame (fist close to the lens); the classifier estimates it.
        guard joints.count >= 8, joints[.middleMCP] != nil || joints[.indexMCP] != nil else { return nil }
        return HandPose(joints: joints, confidence: Double(obs.confidence))
    }
}
