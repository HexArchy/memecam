import MemeCamCore
import SwiftUI

/// Live camera + face guide → neutral-face calibration → "try it" moment.
struct CalibrationStep: View {
    let onCalibrated: () -> Void
    let onNext: () -> Void
    let onFinish: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Phase: Equatable { case aligning, measuring, success, tryIt, nailed }

    @State private var phase: Phase = .aligning
    /// Saw the pipeline report progress < 1 since `calibrate()`; the next 1 means finished.
    @State private var sawMeasuring = false
    @State private var noFaceHint = false
    @State private var burst = 0
    @State private var nailed: Reaction?

    private var running: Bool { model.cameraState == .running }
    private var tryingOut: Bool { phase == .tryIt || phase == .nailed }

    var body: some View {
        let status = model.status
        VStack(spacing: 0) {
            StepHeader(title: title, subtitle: subtitle(faceVisible: status.faceVisible))
                .animation(OnboardingStyle.spring(reduceMotion), value: phase)
                .frame(height: 92, alignment: .top)
            Spacer(minLength: 10)
            stage(status)
            Spacer(minLength: 14)
            actions
                .frame(height: 52)
        }
        .padding(.horizontal, OnboardingStyle.contentPadding)
        .padding(.top, 26)
        .padding(.bottom, 6)
        .onAppear { if model.cameraState != .running, model.cameraState != .starting { model.start() } }
        .task(id: AutoKey(phase: phase, running: running, faceVisible: status.faceVisible)) {
            await watchFace(faceVisible: status.faceVisible)
        }
        .task(id: phase) { await phaseTimers() }
        .onChange(of: status.calibrationProgress) { _, progress in
            guard phase == .measuring else { return }
            if progress < 1 { sawMeasuring = true } else if sawMeasuring { complete() }
        }
        .onChange(of: status.reaction) { _, reaction in
            guard tryingOut, reaction != .neutral, reaction != .noFace else { return }
            nailed = reaction
            if phase == .tryIt {
                withAnimation(OnboardingStyle.bouncy(reduceMotion)) { phase = .nailed }
                burst += 1
            }
        }
    }

    // MARK: Stage

    @ViewBuilder
    private func stage(_ status: PipelineStatus) -> some View {
        switch model.cameraState {
        case .denied:
            CameraProblem(symbol: "lock.shield", tint: .orange,
                          message: String(localized: "Allow MemeCam to use the camera in System Settings \u{203A} Privacy & Security \u{203A} Camera. Video never leaves your Mac."))
        case .failed(let message):
            CameraProblem(symbol: "video.slash", tint: .red, message: message)
        case .idle, .starting:
            ProgressView("Starting camera\u{2026}")
                .controlSize(.large)
                .frame(maxHeight: .infinity)
        case .running:
            liveStage(status)
        }
    }

    private func liveStage(_ status: PipelineStatus) -> some View {
        let maxWidth: CGFloat = tryingOut ? 330 : 600
        let height = min(250, maxWidth / model.layout.cameraAspect)
        return HStack(spacing: 18) {
            CameraViewport(layer: model.preview.layer, layout: model.layout, guide: guide(status))
                .frame(height: height)
                .overlay { SparkleBurst(trigger: burst, radius: 150) }
                .overlay(alignment: .bottom) {
                    if tryingOut {
                        LiveReactionPill(reaction: status.reaction, celebrating: phase == .nailed)
                            .padding(.bottom, 12)
                            .transition(.scale(0.8).combined(with: .opacity))
                    }
                }
            if tryingOut {
                Image(systemName: "arrow.right")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Design.tertiaryText)
                    .transition(.opacity)
                LiveMemeCard(meme: status.meme, reaction: status.reaction)
                    .frame(width: 200, height: 200)
                    .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(OnboardingStyle.spring(reduceMotion), value: tryingOut)
    }

    private func guide(_ status: PipelineStatus) -> FaceGuideState {
        switch phase {
        case .aligning: status.faceVisible ? .locked : .searching
        case .measuring: .measuring(sawMeasuring ? status.calibrationProgress : 0)
        case .success: .done
        case .tryIt, .nailed: .hidden
        }
    }

    // MARK: Actions

    @ViewBuilder
    private var actions: some View {
        switch model.cameraState {
        case .denied:
            HStack(spacing: 12) {
                Button("Open Privacy Settings") { model.openCameraPrivacySettings() }
                    .onboardingPrimary()
                    .keyboardShortcut(.defaultAction)
                Button("Try Again") { model.start() }
                    .controlSize(.extraLarge)
                    .glassButtonStyle()
            }
        case .failed:
            Button("Try Again") { model.start() }
                .onboardingPrimary()
                .keyboardShortcut(.defaultAction)
        case .idle, .starting:
            Color.clear
        case .running:
            runningActions
        }
    }

    @ViewBuilder
    private var runningActions: some View {
        switch phase {
        case .aligning:
            VStack(spacing: 6) {
                Button("Calibrate Now", action: startMeasuring)
                    .onboardingPrimary()
                    .keyboardShortcut(.defaultAction)
                Text("Starts by itself once your face is steady")
                    .font(.caption)
                    .foregroundStyle(Design.tertiaryText)
            }
        case .measuring:
            Label("Measuring\u{2026}", systemImage: "waveform.path.ecg")
                .font(.title3)
                .foregroundStyle(Design.secondaryText)
                .symbolEffect(.pulse, isActive: !reduceMotion)
        case .success:
            Color.clear
        case .tryIt, .nailed:
            HStack(spacing: 12) {
                Button("Finish", action: onFinish)
                    .controlSize(.extraLarge)
                    .font(.title3)
                    .glassButtonStyle()
                Button(action: onNext) { Label("Next: Memes", systemImage: "arrow.right") }
                    .labelStyle(.titleAndIcon)
                    .onboardingPrimary()
                    .keyboardShortcut(.defaultAction)
            }
            .transition(.opacity)
        }
    }

    // MARK: Copy

    private var title: String {
        switch model.cameraState {
        case .denied: return String(localized: "Camera access is off")
        case .failed: return String(localized: "Couldn't start the camera")
        case .idle, .starting: return String(localized: "Relax your face and look at the camera")
        case .running: break
        }
        switch phase {
        case .aligning: return String(localized: "Relax your face and look at the camera")
        case .measuring: return String(localized: "Hold still\u{2026}")
        case .success: return String(localized: "You're calibrated!")
        case .tryIt: return String(localized: "Now smile or show \u{1F44D}")
        case .nailed: return String(localized: "Nailed it!")
        }
    }

    private func subtitle(faceVisible: Bool) -> String? {
        guard running else { return model.cameraState == .denied ? nil : String(localized: "MemeCam needs a few frames of your neutral face.") }
        switch phase {
        case .aligning:
            if noFaceHint, !faceVisible { return String(localized: "Can't see a face yet \u{2014} move into the oval and check the lighting.") }
            return faceVisible ? String(localized: "Perfect \u{2014} keep still for a moment.") : String(localized: "Fit your face inside the oval.")
        case .measuring: return String(localized: "Measuring your neutral face.")
        case .success: return String(localized: "Reactions are now tuned to your face.")
        case .tryIt: return String(localized: "Watch MemeCam react in real time.")
        case .nailed:
            let name = nailed?.title ?? String(localized: "Reaction")
            return String(localized: "\(name) \u{2192} meme. It works like this in every call.")
        }
    }

    // MARK: Logic

    private struct AutoKey: Equatable {
        let phase: Phase
        let running: Bool
        let faceVisible: Bool
    }

    /// Auto-calibrates after the face has been steadily visible for ~1.5 s; hints when no face shows up.
    private func watchFace(faceVisible: Bool) async {
        guard phase == .aligning, running else { return }
        if faceVisible {
            noFaceHint = false
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, phase == .aligning else { return }
            startMeasuring()
        } else {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            withAnimation { noFaceHint = true }
        }
    }

    private func phaseTimers() async {
        switch phase {
        case .measuring:
            // Safety net: the pipeline needs ~15 face frames. Without a face it never finishes.
            try? await Task.sleep(for: .seconds(7))
            guard !Task.isCancelled, phase == .measuring else { return }
            if sawMeasuring, model.status.calibrationProgress < 1 {
                noFaceHint = true
                withAnimation(OnboardingStyle.spring(reduceMotion)) { phase = .aligning }
            } else {
                complete()
            }
        case .success:
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled, phase == .success else { return }
            withAnimation(OnboardingStyle.spring(reduceMotion)) { phase = .tryIt }
        default:
            break
        }
    }

    private func startMeasuring() {
        guard running, phase == .aligning else { return }
        sawMeasuring = false
        model.calibrate()
        withAnimation(OnboardingStyle.spring(reduceMotion)) { phase = .measuring }
    }

    private func complete() {
        guard phase == .measuring else { return }
        onCalibrated()
        withAnimation(OnboardingStyle.bouncy(reduceMotion)) { phase = .success }
        burst += 1
    }
}

/// The reaction MemeCam currently sees, in a glass capsule.
private struct LiveReactionPill: View {
    let reaction: Reaction
    let celebrating: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Label {
            Text(reaction.title).contentTransition(.opacity)
        } icon: {
            Image(systemName: reaction.displaySymbol)
                .foregroundStyle(Design.brand)
                .contentTransition(.symbolEffect(.replace))
        }
        .font(.headline)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassSurface(in: .capsule)
        .overlay {
            Capsule().strokeBorder(OnboardingStyle.success.opacity(celebrating ? 0.9 : 0), lineWidth: 2)
        }
        .animation(reduceMotion ? nil : .snappy, value: reaction)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Detected: \(reaction.title)")
    }
}

/// The meme currently chosen by the pipeline (first frame), cross-fading on change.
private struct LiveMemeCard: View {
    let meme: Meme?
    let reaction: Reaction
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            MemeThumbnail(url: meme?.url, id: meme?.id, symbol: reaction.displaySymbol, maxPixelSize: 400)
                .id(meme?.id)
                .transition(reduceMotion ? AnyTransition.opacity : .opacity.combined(with: .scale(scale: 0.92)))
        }
        .clipShape(.rect(cornerRadius: 24))
        .overlay { RoundedRectangle(cornerRadius: 24).strokeBorder(.white.opacity(0.14)) }
        .shadow(color: .black.opacity(0.22), radius: 18, y: 9)
        .animation(.smooth(duration: 0.35), value: meme?.id)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(meme.map { String(localized: "Meme: \($0.title)") } ?? String(localized: "No meme yet"))
    }
}

/// Camera denied / failed placeholder inside the calibration step.
private struct CameraProblem: View {
    let symbol: String
    let tint: Color
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 54))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(Design.secondaryText)
                .frame(maxWidth: 420)
        }
        .frame(maxHeight: .infinity)
    }
}
