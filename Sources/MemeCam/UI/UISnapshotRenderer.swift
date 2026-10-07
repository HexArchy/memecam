#if DEBUG
import AppKit
import MemeCamCore
import SwiftUI

/// Dev tool: renders the onboarding steps, the virtual-camera health popover and the "Be right back" card
/// to PNGs, to review layouts in every language without clicking through the app.
/// `MEMECAM_RENDER_UI=<dir> swift run MemeCam -AppleLanguages '(ru)'` writes the PNGs and exits (debug
/// builds only). A bare `swift run` binary finds translations next to itself: link
/// `Resources/Localization/ru.lproj` into `.build/debug/` first.
enum UISnapshotRenderer {
    static func runIfRequested() {
        guard let dir = ProcessInfo.processInfo.environment["MEMECAM_RENDER_UI"] else { return }
        MainActor.assumeIsolated { render(to: URL(filePath: dir, directoryHint: .isDirectory)) }
    }

    @MainActor
    private static func render(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let model = AppModel()
        let ui = UIState()
        let card = OnboardingStyle.cardSize

        func step(_ view: some View) -> AnyView {
            AnyView(view
                .frame(width: card.width, height: card.height - 40)
                .padding(.bottom, 40)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(model)
                .environment(ui))
        }

        var jobs: [(name: String, view: AnyView)] = [
            ("onboarding-1-welcome", step(WelcomeStep(onStart: {}, onSkip: {}))),
            ("onboarding-2-path", step(PathStep(onCalibrate: {}, onMemes: {}, onDefaults: {}))),
            ("onboarding-2-path-light", step(PathStep(onCalibrate: {}, onMemes: {}, onDefaults: {}))),
            ("onboarding-4-memes", step(MemesStep(onContinue: {}, onOpenEditor: {}))),
            ("onboarding-5-done", step(DoneStep(calibrated: true, onStart: {}))),
            ("virtual-camera-health", AnyView(VirtualCameraDetail()
                .frame(width: 320)
                .padding()
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(model))),
        ]
        let row = { (r: Reaction, before: Double, after: Double, on: Bool, confused: Reaction?) in
            PersonalizationReport.Row(reaction: r, rulesF1: before, personalF1: after, support: 60,
                                      confusedWith: confused, enabled: on, optimistic: false)
        }
        let taught = PersonalizationReport(
            rows: [row(.sad, 0, 0.71, true, nil), row(.thinking, 0.42, 0.95, true, nil), row(.peace, 0.3, 0.73, true, nil),
                   row(.neutral, 0.59, 0.75, true, nil), row(.eyebrowsRaised, 0.4, 0.45, false, .surprised)],
            macroBefore: 0.83, macroAfter: 0.94, outcome: .accepted)
        jobs.append(("teach-result", AnyView(TeachResultCard(report: taught)
            .frame(width: 640).padding().background(Color(nsColor: .windowBackgroundColor)).environment(model))))
        jobs.append(("teach-result-notbetter", AnyView(TeachResultCard(report: PersonalizationReport(
            rows: [], macroBefore: 0.9, macroAfter: 0.9, outcome: .notBetter))
            .frame(width: 640).padding().background(Color(nsColor: .windowBackgroundColor)).environment(model))))
        jobs.append(("settings", AnyView(SettingsForm()
            .frame(width: 360, height: 1500).background(Color(nsColor: .windowBackgroundColor))
            .environment(model).environment(ui))))
        for (name, size) in [("main-fullscreen-1512", CGSize(width: 1512, height: 982)),
                             ("main-fullscreen-1920", CGSize(width: 1920, height: 1080))] {
            jobs.append((name, AnyView(VStack(spacing: Design.sectionSpacing) {
                PreviewStage(); ControlBar(); ReactionStrip()
            }
            .padding(.horizontal, Design.stagePadding).padding(.top, 8).padding(.bottom, 18)
            .frame(width: size.width - 340, height: size.height)
            .background { WindowBackdrop() }
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(model).environment(ui))))
        }
        for phase in CalibrationCopyPreview.Phase.allCases {
            jobs.append(("onboarding-3-calibrate-\(phase.rawValue)", step(CalibrationCopyPreview(phase: phase))))
        }

        if let away = AwayCard.render(title: String(localized: "Be right back")) {
            write(NSBitmapImageRep(cgImage: away), to: dir.appending(path: "away-card.png"))
        }

        Task { @MainActor in
            var windows: [NSWindow] = []
            for job in jobs {
                let host = NSHostingView(rootView: job.view)
                host.frame.size = host.fittingSize
                let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20_000, y: 0), size: host.frame.size),
                                      styleMask: .borderless, backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: job.name.hasSuffix("-light") ? .aqua : .darkAqua)
                window.contentView = host
                window.orderFrontRegardless()
                windows.append(window)
            }
            // Let the staggered entrance animations finish. `cacheDisplay` draws text and layout faithfully
            // but not Liquid Glass (glass buttons come out as bare labels) — this is a layout check.
            try? await Task.sleep(for: .seconds(2.5))
            for (job, window) in zip(jobs, windows) {
                guard let view = window.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                write(rep, to: dir.appending(path: "\(job.name).png"))
            }
            print("wrote \(jobs.count + 1) images to \(dir.path)")
            exit(0)
        }
        app.run()
    }

    private static func write(_ rep: NSBitmapImageRep, to url: URL) {
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

/// The calibration step's copy and buttons per phase at their real size, around a placeholder camera
/// (the step itself needs a running camera). Red outlines mark the header's fixed 92 pt box and the
/// 52 pt action row: text must stay inside them.
private struct CalibrationCopyPreview: View {
    enum Phase: String, CaseIterable { case aligning, noFace, measuring, success, tryIt, nailed, denied, failed }
    let phase: Phase

    var body: some View {
        VStack(spacing: 0) {
            StepHeader(title: header.title, subtitle: header.subtitle)
                .frame(height: 92, alignment: .top)
                .border(.red.opacity(0.6))
            Spacer(minLength: 10)
            RoundedRectangle(cornerRadius: 24).fill(.quaternary).frame(width: 444, height: 250)
            Spacer(minLength: 14)
            actions
                .frame(height: 52)
                .border(.red.opacity(0.6))
        }
        .padding(.horizontal, OnboardingStyle.contentPadding)
        .padding(.top, 26)
        .padding(.bottom, 6)
    }

    private var header: (title: String, subtitle: String?) {
        switch phase {
        case .aligning: (String(localized: "Relax your face and look at the camera"), String(localized: "Fit your face inside the oval."))
        case .noFace: (String(localized: "Relax your face and look at the camera"),
                       String(localized: "Can't see a face yet \u{2014} move into the oval and check the lighting."))
        case .measuring: (String(localized: "Hold still\u{2026}"), String(localized: "Measuring your neutral face."))
        case .success: (String(localized: "You're calibrated!"), String(localized: "Reactions are now tuned to your face."))
        case .tryIt: (String(localized: "Now smile or show \u{1F44D}"), String(localized: "Watch MemeCam react in real time."))
        case .nailed: (String(localized: "Nailed it!"),
                       String(localized: "\(Reaction.thumbsDown.title) \u{2192} meme. It works like this in every call."))
        case .denied: (String(localized: "Camera access is off"), nil)
        case .failed: (String(localized: "Couldn't start the camera"), String(localized: "MemeCam needs a few frames of your neutral face."))
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch phase {
        case .aligning, .noFace:
            VStack(spacing: 6) {
                Button("Calibrate Now") {}.onboardingPrimary()
                Text("Starts by itself once your face is steady").font(.caption).foregroundStyle(Design.tertiaryText)
            }
        case .measuring:
            Label("Measuring\u{2026}", systemImage: "waveform.path.ecg").font(.title3).foregroundStyle(Design.secondaryText)
        case .success:
            Color.clear
        case .tryIt, .nailed:
            HStack(spacing: 12) {
                Button("Finish") {}.controlSize(.extraLarge).font(.title3).glassButtonStyle()
                Button {} label: { Label("Next: Memes", systemImage: "arrow.right") }
                    .labelStyle(.titleAndIcon).onboardingPrimary()
            }
        case .denied:
            HStack(spacing: 12) {
                Button("Open Privacy Settings") {}.onboardingPrimary()
                Button("Try Again") {}.controlSize(.extraLarge).glassButtonStyle()
            }
        case .failed:
            Button("Try Again") {}.onboardingPrimary()
        }
    }
}
#endif
