import AppKit
import MemeCamCore
import SwiftUI

/// Stage overlay for the interactive accuracy test: "get ready" card with instructions and a
/// countdown, then a "hold it" card with a filling ring and live detection feedback.
/// Keyboard: Space pause/resume, → skip, ← redo previous, Esc cancel.
struct AccuracyTestOverlay: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let g = model.status.guided {
                running(g)
                    .transition(.opacity)
            } else if model.showEvaluationResult, let report = model.lastEvaluation {
                ResultCard(report: report)
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .smooth, value: model.status.guided?.stepIndex)
        .animation(reduceMotion ? nil : .smooth, value: model.showEvaluationResult)
    }

    private func running(_ g: GuidedSession.Snapshot) -> some View {
        VStack(spacing: 0) {
            ProgressView(value: g.overallProgress)
                .progressViewStyle(.linear)
                .tint(Design.brand)
                .padding(.horizontal, 24)
                .padding(.top, 14)
            Spacer()
            PromptCard(snapshot: g, detected: model.status.reaction)
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

    private var matched: Bool { snapshot.phase == .hold && detected == snapshot.reaction }

    var body: some View {
        HStack(spacing: 18) {
            CountdownRing(snapshot: snapshot, matched: matched)
            VStack(alignment: .leading, spacing: 6) {
                Text(snapshot.phase == .prepare ? "Get ready · \(snapshot.stepIndex + 1) of \(snapshot.stepCount)"
                                                : (snapshot.paused ? "Paused" : "Hold it!"))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(snapshot.phase == .prepare ? .secondary : Design.brand)
                    .contentTransition(.opacity)
                Text(snapshot.reaction.title)
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                Text(snapshot.reaction.howTo)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if snapshot.phase == .hold {
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
