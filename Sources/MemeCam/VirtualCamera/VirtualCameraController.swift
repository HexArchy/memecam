import CoreMedia
import CoreVideo
import Foundation
import Observation

enum VirtualCameraState: Equatable, Sendable {
    case checking
    /// Extension not activated yet (first launch).
    case notInstalled
    /// Activation requested; user must allow it in System Settings.
    case awaitingApproval
    /// Installed, waiting to connect to the extension's sink stream.
    case connecting
    /// Frames are flowing into the virtual camera.
    case streaming
    case failed(String)

    var title: String {
        switch self {
        case .checking: "Checking…"
        case .notInstalled: "Not Installed"
        case .awaitingApproval: "Waiting for Approval"
        case .connecting: "Connecting…"
        case .streaming: "Live"
        case .failed: "Unavailable"
        }
    }
}

/// Owns the CoreMediaIO camera extension lifecycle and the app → extension frame feed.
/// TODO(virtual-camera agent): implement activation + sink feeding.
@MainActor @Observable
final class VirtualCameraController {
    private(set) var state: VirtualCameraState = .checking
    /// Add to the pipeline; forwards composited frames to the extension's sink stream.
    let sink = VirtualCameraSink()

    func refresh() { state = .notInstalled }
    func install() {}
    func openSystemSettings() {}
}

final class VirtualCameraSink: FrameSink, @unchecked Sendable {
    func send(_ pixelBuffer: CVPixelBuffer, time: CMTime) {}
}
