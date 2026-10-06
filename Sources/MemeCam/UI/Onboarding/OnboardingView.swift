import SwiftUI

enum OnboardingStep: Int, CaseIterable, Identifiable {
    case welcome, path, calibrate, memes, done
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .welcome: "Welcome"
        case .path: "Choose a Start"
        case .calibrate: "Calibrate"
        case .memes: "Memes"
        case .done: "Done"
        }
    }
}

/// How the onboarding was left.
enum OnboardingExit {
    /// Skipped / closed: keep whatever state the user had before.
    case skip
    /// "Start MemeCam" on the last step.
    case start
    /// Jump into the meme editor.
    case openMemeEditor
}

/// Full-window first-launch onboarding: material backdrop + a centred card with the steps.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(UIState.self) private var ui
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Called after the user leaves the onboarding (the caller marks it completed and hides it).
    let onClose: () -> Void

    @State private var history: [OnboardingStep] = [.welcome]
    @State private var forward = true
    @State private var cameraWasRunning = false
    @State private var calibrated = false
    @State private var cardVisible = false

    private var step: OnboardingStep { history.last ?? .welcome }

    var body: some View {
        ZStack {
            OnboardingBackdrop()
            card
                .scaleEffect(cardVisible || reduceMotion ? 1 : 0.94)
                .opacity(cardVisible ? 1 : 0)
                .animation(OnboardingStyle.bouncy(reduceMotion), value: cardVisible)
        }
        .onAppear {
            cameraWasRunning = model.cameraState == .running
            cardVisible = true
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("MemeCam setup")
        .accessibilityAddTraits(.isModal)
    }

    private var card: some View {
        VStack(spacing: 0) {
            ZStack {
                stepView
                    .id(step)
                    .transition(stepTransition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            footer
        }
        .frame(width: OnboardingStyle.cardSize.width, height: OnboardingStyle.cardSize.height)
        .background { OnboardingCardBackground() }
        .clipShape(.rect(cornerRadius: OnboardingStyle.cardRadius))
        .overlay {
            RoundedRectangle(cornerRadius: OnboardingStyle.cardRadius)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.28), radius: 40, y: 18)
    }

    @ViewBuilder
    private var stepView: some View {
        switch step {
        case .welcome:
            WelcomeStep(onStart: { go(to: .path) }, onSkip: { finish(.skip) })
        case .path:
            PathStep(onCalibrate: { go(to: .calibrate) }, onMemes: { go(to: .memes) }, onDefaults: { go(to: .done) })
        case .calibrate:
            CalibrationStep(onCalibrated: { calibrated = true },
                            onNext: { go(to: .memes) },
                            onFinish: { go(to: .done) })
        case .memes:
            MemesStep(onContinue: { go(to: .done) }, onOpenEditor: { finish(.openMemeEditor) })
        case .done:
            DoneStep(calibrated: calibrated, onStart: { finish(.start) })
        }
    }

    private var footer: some View {
        HStack {
            if history.count > 1 {
                Button("Back", systemImage: "chevron.left") { back() }
                    .labelStyle(.titleAndIcon)
                    .onboardingSecondary()
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                    .help("Go back (\u{2318}\u{2190})")
                    .transition(.opacity)
            }
            Spacer()
            if step != .welcome {
                Button(step == .done ? "Close" : "Skip") { finish(.skip) }
                    .onboardingSecondary()
                    .keyboardShortcut(.cancelAction)
                    .help(step == .done ? "Close without starting the camera (Esc)" : "Skip setup and use the defaults (Esc)")
                    .transition(.opacity)
            }
        }
        .overlay { StepDots(current: step) }
        .frame(height: 22)
        .padding(.horizontal, 24)
        .padding(.bottom, 18)
        .animation(OnboardingStyle.spring(reduceMotion), value: step)
    }

    private var stepTransition: AnyTransition {
        if reduceMotion { return .opacity }
        let distance: CGFloat = 90
        return .asymmetric(
            insertion: .offset(x: forward ? distance : -distance).combined(with: .opacity),
            removal: .offset(x: forward ? -distance : distance).combined(with: .opacity))
    }

    // MARK: Navigation

    private func go(to next: OnboardingStep) {
        forward = true
        withAnimation(OnboardingStyle.spring(reduceMotion)) { history.append(next) }
    }

    private func back() {
        guard history.count > 1 else { return }
        forward = false
        withAnimation(OnboardingStyle.spring(reduceMotion)) { _ = history.popLast() }
    }

    private func finish(_ exit: OnboardingExit) {
        switch exit {
        case .start:
            model.start()
        case .openMemeEditor:
            restoreCamera()
            ui.editMemes()
        case .skip:
            restoreCamera()
        }
        onClose()
    }

    /// Don't leave a camera running that the onboarding switched on, unless it was used to calibrate.
    private func restoreCamera() {
        if !cameraWasRunning, !calibrated, model.cameraState != .idle { model.stop() }
    }
}

/// Capsule-and-dots progress indicator.
struct StepDots: View {
    let current: OnboardingStep

    var body: some View {
        HStack(spacing: 7) {
            ForEach(OnboardingStep.allCases) { step in
                Capsule()
                    .fill(step == current ? AnyShapeStyle(OnboardingStyle.accentGradient)
                          : step.rawValue < current.rawValue ? AnyShapeStyle(.secondary) : AnyShapeStyle(.quaternary))
                    .frame(width: step == current ? 22 : 7, height: 7)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(current.rawValue + 1) of \(OnboardingStep.allCases.count): \(current.title)")
    }
}

/// Window-wide material that dims and blurs the app behind the card, with a slow brand glow.
private struct OnboardingBackdrop: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var drift = false

    var body: some View {
        let strength = colorScheme == .dark ? 0.32 : 0.24
        ZStack {
            Rectangle().fill(.regularMaterial)
            RadialGradient(colors: [Design.brand.opacity(strength), .clear],
                           center: drift ? UnitPoint(x: 0.3, y: 0.15) : UnitPoint(x: 0.12, y: 0.3),
                           startRadius: 0, endRadius: 620)
            RadialGradient(colors: [Color.pink.opacity(strength * 0.8), .clear],
                           center: drift ? UnitPoint(x: 0.75, y: 0.9) : UnitPoint(x: 0.92, y: 0.7),
                           startRadius: 0, endRadius: 560)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 9).repeatForever(autoreverses: true)) { drift = true }
        }
    }
}

/// Opaque card surface with a faint warm wash at the top, legible in light and dark mode.
private struct OnboardingCardBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Rectangle().fill(Color(nsColor: .windowBackgroundColor))
            LinearGradient(colors: [Design.brand.opacity(colorScheme == .dark ? 0.14 : 0.10), .clear],
                           startPoint: .top, endPoint: .center)
        }
    }
}
