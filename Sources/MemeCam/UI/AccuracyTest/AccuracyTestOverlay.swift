import AppKit
import MemeCamCore
import SwiftUI

/// Stage overlay for the interactive accuracy test and for teaching: "get ready" card with instructions
/// and a countdown, then a "hold it" card with a filling ring (live detection feedback in the test).
/// Afterwards: the test's result card, or "learning…" and the teaching result.
/// Keyboard: Space pause/resume, → skip, ← redo previous, Esc cancel.
struct AccuracyTestOverlay: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let g = model.guided {
                running(g)
                    .transition(.opacity)
            } else if model.teachingPhase == .training {
                LearningCard()
                    .transition(.opacity)
            } else if model.showTeachResult, let report = model.personalReport {
                TeachResultCard(report: report)
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
            } else if model.showEvaluationResult, let report = model.lastEvaluation {
                ResultCard(report: report)
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .smooth, value: model.guided?.stepIndex)
        .animation(reduceMotion ? nil : .smooth, value: model.showEvaluationResult)
        .animation(reduceMotion ? nil : .smooth, value: model.showTeachResult)
        .animation(reduceMotion ? nil : .smooth, value: model.teachingPhase)
    }

    private func running(_ g: GuidedSession.Snapshot) -> some View {
        VStack(spacing: 0) {
            ProgressView(value: g.overallProgress)
                .progressViewStyle(.linear)
                .tint(Design.accent)
                .padding(.horizontal, 24)
                .padding(.top, 14)
            Spacer()
            PromptCard(snapshot: g, detected: model.liveReaction)
                .id(g.stepIndex) // fresh transition per reaction
                .transition(reduceMotion ? .opacity : .asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)))
                .padding(.bottom, 18)
            Controls(paused: g.paused)
                .padding(.bottom, 16)
        }
    }
}

private struct PromptCard: View {
    let snapshot: GuidedSession.Snapshot
    let detected: Reaction

    private var matched: Bool { !snapshot.teaching && snapshot.phase == .hold && detected == snapshot.reaction }

    private var title: LocalizedStringKey {
        if snapshot.paused { return "Paused" }
        if snapshot.phase == .prepare {
            return snapshot.teaching ? "Teaching \u{00B7} \(snapshot.stepIndex + 1) of \(snapshot.stepCount)"
                                     : "Get ready \u{00B7} \(snapshot.stepIndex + 1) of \(snapshot.stepCount)"
        }
        return snapshot.teaching ? "Recording \u{2014} keep it up!" : "Hold it!"
    }

    var body: some View {
        HStack(spacing: 18) {
            CountdownRing(snapshot: snapshot, matched: matched)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(snapshot.phase == .prepare ? Design.secondaryText : Design.brand)
                    .contentTransition(.opacity)
                Text(snapshot.reaction.title)
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                Text(snapshot.reaction.howTo)
                    .font(.title3)
                    .foregroundStyle(Design.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if let hint = snapshot.teaching ? snapshot.reaction.teachHint(take: snapshot.take) : nil {
                    Label(hint, systemImage: "sparkles")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Design.accent)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if snapshot.phase == .hold, !snapshot.teaching {
                    Label {
                        Text("MemeCam sees: \(detected.title)")
                    } icon: {
                        Image(systemName: matched ? "checkmark.circle.fill" : "eye")
                            .foregroundStyle(matched ? .green : .secondary)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .font(.callout.weight(.medium))
                    .padding(.top, 2)
                    .accessibilityLabel(matched ? "Detected correctly" : "MemeCam sees \(detected.title)")
                }
            }
            .frame(maxWidth: 420, alignment: .leading)
        }
        .padding(20)
        .glassSurface(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(matched ? Color.green.opacity(0.7) : .clear, lineWidth: 2)
        }
        .animation(.smooth(duration: 0.25), value: matched)
        .animation(.smooth(duration: 0.25), value: snapshot.phase)
    }
}

private struct CountdownRing: View {
    let snapshot: GuidedSession.Snapshot
    let matched: Bool

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 8)
            Circle()
                .trim(from: 0, to: snapshot.phase == .prepare ? 1 - snapshot.phaseProgress : snapshot.phaseProgress)
                .stroke(snapshot.phase == .prepare ? AnyShapeStyle(.secondary)
                                                   : AnyShapeStyle(matched ? Color.green : Design.brand),
                        style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.12), value: snapshot.phaseProgress)
            if snapshot.phase == .prepare {
                Text("\(Int(snapshot.remaining.rounded(.up)))")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.smooth, value: Int(snapshot.remaining.rounded(.up)))
            } else {
                Image(systemName: snapshot.reaction.displaySymbol)
                    .font(.system(size: 30, weight: .semibold))
                    .symbolEffect(.bounce, value: matched)
            }
        }
        .frame(width: 84, height: 84)
        .accessibilityHidden(true)
    }
}

private struct Controls: View {
    @Environment(AppModel.self) private var model
    let paused: Bool

    var body: some View {
        GlassGroup(spacing: 8) {
            HStack(spacing: 8) {
                Button("Redo", systemImage: "arrow.uturn.backward") { model.redoAccuracyStep() }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .help("Redo the previous reaction (←)")
                Button(paused ? "Resume" : "Pause", systemImage: paused ? "play.fill" : "pause.fill") {
                    model.togglePauseAccuracyTest()
                }
                .keyboardShortcut(.space, modifiers: [])
                .help("Pause or resume (Space)")
                Button("Skip", systemImage: "forward.fill") { model.skipAccuracyStep() }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .help("Skip this reaction (→)")
                Button("Stop", systemImage: "xmark") { model.cancelAccuracyTest() }
                    .keyboardShortcut(.cancelAction)
                    .help("Stop the test (Esc)")
            }
            .glassButtonStyle()
            .controlSize(.large)
        }
    }
}

/// Shown for the second or two the personal model takes to build.
private struct LearningCard: View {
    var body: some View {
        HStack(spacing: 14) {
            ProgressView().controlSize(.large)
            VStack(alignment: .leading, spacing: 2) {
                Text("Learning your reactions\u{2026}").font(.title3.weight(.semibold))
                Text("Making sure it really recognises you better").foregroundStyle(Design.secondaryText)
            }
        }
        .padding(22)
        .glassSurface(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

/// What teaching changed: accuracy on the user's face before and after, per reaction, with a way to
/// re-teach reactions that MemeCam still mixes up.
struct TeachResultCard: View {
    @Environment(AppModel.self) private var model
    let report: PersonalizationReport

    private var improved: [PersonalizationReport.Row] {
        report.rows.filter { $0.enabled && $0.personalF1 > $0.rulesF1 + 0.005 }
    }
    /// Reactions MemeCam still gets wrong after teaching (not used, weak).
    private var weak: [PersonalizationReport.Row] {
        report.rows.filter { !$0.enabled && $0.reaction != .neutral && max($0.rulesF1, $0.personalF1) < 0.6 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if !improved.isEmpty || !weak.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(improved, id: \.reaction) { row in
                            ResultRow(row: row, improved: true)
                        }
                        ForEach(weak, id: \.reaction) { row in
                            ResultRow(row: row, improved: false)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
            }
            HStack {
                if report.accepted {
                    Button("Check with Accuracy Test", systemImage: "checklist") {
                        model.showTeachResult = false
                        model.startAccuracyTest()
                    }
                }
                Spacer()
                Button("Done") { model.showTeachResult = false }
                    .keyboardShortcut(.defaultAction)
                    .glassButtonStyle(prominent: true)
            }
        }
        .padding(22)
        .frame(maxWidth: 560)
        .glassSurface(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(24)
    }

    @ViewBuilder private var header: some View {
        switch report.outcome {
        case .accepted:
            Label("MemeCam learned your reactions", systemImage: "graduationcap.fill")
                .font(.system(.title2, design: .rounded).weight(.bold))
                .foregroundStyle(Design.brand)
            Text("Recognises your face better: \(percent(report.macroBefore)) \u{2192} \(percent(report.macroAfter)).")
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
        case .notBetter:
            Label("MemeCam already recognises you well", systemImage: "checkmark.seal.fill")
                .font(.system(.title2, design: .rounded).weight(.bold))
                .foregroundStyle(Design.brand)
            Text("Teaching didn't make it better this time, so nothing changes. You can teach single reactions again any time.")
                .foregroundStyle(Design.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        case .notEnoughData:
            Label("Not enough to learn from", systemImage: "exclamationmark.triangle.fill")
                .font(.system(.title2, design: .rounded).weight(.bold))
                .foregroundStyle(.orange)
            Text("MemeCam couldn't see your face or hands long enough. Try again in good light, facing the camera.")
                .foregroundStyle(Design.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
}

private struct ResultRow: View {
    @Environment(AppModel.self) private var model
    let row: PersonalizationReport.Row
    let improved: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: row.reaction.displaySymbol)
                .frame(width: 22)
                .foregroundStyle(improved ? Design.accent : Design.secondaryText)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.reaction.title).font(.body.weight(.medium))
                if !improved {
                    Text(row.confusedWith.map { "Still looks like \($0.title) to MemeCam \u{2014} make it stronger." }
                         ?? "MemeCam couldn't tell it apart yet.")
                        .font(.caption)
                        .foregroundStyle(Design.secondaryText)
                }
            }
            Spacer()
            if improved {
                Text("\(Int((row.rulesF1 * 100).rounded()))% \u{2192} \(Int((row.personalF1 * 100).rounded()))%")
                    .monospacedDigit()
                    .foregroundStyle(Design.secondaryText)
                Image(systemName: "arrow.up.circle.fill").foregroundStyle(.green)
            } else {
                Button("Teach Again") { model.startTeaching([row.reaction]) }
                    .controlSize(.small)
            }
        }
    }
}

private struct ResultCard: View {
    @Environment(AppModel.self) private var model
    let report: String

    private var headline: String { report.split(separator: "\n").first.map(String.init) ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Accuracy test complete", systemImage: "checkmark.seal.fill")
                .font(.system(.title2, design: .rounded).weight(.bold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Design.brand)
            Text(headline).font(.headline)
            ScrollView {
                Text(report.split(separator: "\n").dropFirst().joined(separator: "\n"))
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 260)
            HStack {
                Button("Copy Report", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report, forType: .string)
                }
                Button("Show Recording", systemImage: "folder") { model.revealRecordings() }
                if !model.reactionsToImprove.isEmpty {
                    Button("Teach the Weak Ones", systemImage: "graduationcap") {
                        model.startTeaching(model.reactionsToImprove)
                    }
                    .help("Show MemeCam the reactions it got wrong, twice each")
                }
                Spacer()
                Button("Done") { model.showEvaluationResult = false }
                    .keyboardShortcut(.defaultAction)
                    .glassButtonStyle(prominent: true)
            }
        }
        .padding(22)
        .frame(maxWidth: 640)
        .glassSurface(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(24)
    }
}
