import Foundation

extension Reaction {
    /// One-line instruction for performing the reaction (accuracy test, onboarding).
    public var howTo: String {
        switch self {
        case .neutral: String(localized: "Relax your face and look at the camera.", bundle: .main)
        case .smile: String(localized: "Smile with your mouth closed.", bundle: .main)
        case .laugh: String(localized: "Laugh — big open-mouth smile.", bundle: .main)
        case .surprised: String(localized: "Drop your jaw: mouth wide open, like “whoa!”.", bundle: .main)
        case .eyebrowsRaised: String(localized: "Raise both eyebrows high, keep your mouth closed.", bundle: .main)
        case .eyesClosed: String(localized: "Close your eyes gently and keep them closed.", bundle: .main)
        case .sad: String(localized: "Pout: pull the lip corners down, inner eyebrows up.", bundle: .main)
        case .headTilt: String(localized: "Tilt your head toward one shoulder.", bundle: .main)
        case .thumbsUp: String(localized: "Thumbs up 👍 next to your face.", bundle: .main)
        case .thumbsDown: String(localized: "Thumbs down 👎 next to your face.", bundle: .main)
        case .peace: String(localized: "Peace sign ✌️ — palm toward the camera.", bundle: .main)
        case .openPalm: String(localized: "Show an open palm ✋ — wave hello.", bundle: .main)
        case .pointing: String(localized: "Point up ☝️ with your index finger.", bundle: .main)
        case .fist: String(localized: "Make a fist ✊ beside your face.", bundle: .main)
        case .handsUp: String(localized: "Raise both open hands above your head 🙌.", bundle: .main)
        case .facepalm: String(localized: "Cover your forehead and eyes with your palm 🤦.", bundle: .main)
        case .thinking: String(localized: "Rest your chin on your hand 🤔.", bundle: .main)
        case .heart: String(localized: "Make a heart 🫶 with both hands in front of your chest.", bundle: .main)
        case .noFace: String(localized: "Step out of the frame.", bundle: .main)
        }
    }

    /// Extra instruction for a repeated take while teaching (nil for the first take): variety makes the
    /// personal model robust, and the talking / reading neutral takes stop false triggers in calls.
    public func teachHint(take: Int) -> String? {
        switch (self, take) {
        case (_, 0): nil
        case (.neutral, 1): String(localized: "Talk as you would in a call \u{2014} say anything.", bundle: .main)
        case (.neutral, _): String(localized: "Look at your screen as if reading.", bundle: .main)
        default: String(localized: "Once more, a little differently: other hand or side, a bit stronger or softer.", bundle: .main)
        }
    }
}

/// Interactive accuracy test: for every reaction a *prepare* phase (instructions + countdown,
/// not recorded) is followed by a *hold* phase (recorded). The user can pause, skip, or redo.
public struct GuidedSession: Sendable {
    public enum Phase: Sendable, Equatable { case prepare, hold }

    public struct Snapshot: Sendable, Equatable {
        public var reaction: Reaction
        public var phase: Phase
        /// 0...1 within the current phase.
        public var phaseProgress: Double
        public var remaining: Double
        public var stepIndex: Int
        public var stepCount: Int
        public var paused: Bool
        /// Teaching session (not the accuracy test).
        public var teaching = false
        /// How many times this reaction came up before in the session (0 = first take).
        public var take = 0
        public var overallProgress: Double { (Double(stepIndex) + (phase == .hold ? 0.5 : 0) + phaseProgress / 2) / Double(stepCount) }
    }

    public var prepareDuration: Double
    public var holdDuration: Double
    /// First part of the hold that is not labelled (the user is still settling).
    public var settle: Double
    public let reactions: [Reaction]
    public let teaching: Bool

    public private(set) var stepIndex = 0
    public private(set) var phase: Phase = .prepare
    private var phaseStart: Double
    private var pausedAt: Double?
    private var frames: [(step: Int, frame: LabeledFrame)] = []
    public private(set) var finished = false

    public init(start: Double, reactions: [Reaction]? = nil,
                prepare: Double = 3.5, hold: Double = 5, settle: Double = 0.6, teaching: Bool = false) {
        self.reactions = reactions ?? ([.neutral] + Reaction.allCases.filter { $0 != .neutral && $0 != .noFace } + [.noFace])
        self.teaching = teaching
        prepareDuration = prepare
        holdDuration = hold
        self.settle = settle
        phaseStart = start
    }

    public var isPaused: Bool { pausedAt != nil }

    /// "Teach MemeCam": every reaction twice in two separate passes (validation needs takes that weren't
    /// learned from), framed by neutral takes: calm, talking, reading. About 4 s per hold, like the
    /// "a few seconds per class, varied" practice of example-based trainers (Teachable Machine).
    public static func teaching(start: Double, reactions: [Reaction]) -> GuidedSession {
        GuidedSession(start: start, reactions: teachPlan(reactions), prepare: 2.5, hold: 4, teaching: true)
    }

    public static func teachPlan(_ reactions: [Reaction]) -> [Reaction] {
        let r = reactions.filter { $0 != .neutral && $0 != .noFace }
        return [.neutral] + r + [.neutral] + r + [.neutral]
    }

    private func duration(of phase: Phase) -> Double {
        // Longer first neutral hold: it doubles as calibration.
        phase == .prepare ? prepareDuration : (stepIndex == 0 ? holdDuration + 3 : holdDuration)
    }

    /// Advances phases by time; call every frame. Returns nil when finished.
    public mutating func tick(_ now: Double) -> Snapshot? {
        guard !finished else { return nil }
        if let p = pausedAt {
            return snapshot(elapsed: p - phaseStart)
        }
        while now - phaseStart >= duration(of: phase) {
            phaseStart += duration(of: phase)
            if phase == .prepare {
                phase = .hold
            } else if !advanceStep() {
                return nil
            }
        }
        return snapshot(elapsed: now - phaseStart)
    }

    private func snapshot(elapsed: Double) -> Snapshot {
        let d = duration(of: phase)
        let reaction = reactions[stepIndex]
        return Snapshot(reaction: reaction, phase: phase, phaseProgress: min(1, elapsed / d),
                        remaining: max(0, d - elapsed), stepIndex: stepIndex, stepCount: reactions.count,
                        paused: pausedAt != nil, teaching: teaching,
                        take: reactions[..<stepIndex].filter { $0 == reaction }.count)
    }

    private mutating func advanceStep() -> Bool {
        stepIndex += 1
        phase = .prepare
        if stepIndex >= reactions.count {
            finished = true
            return false
        }
        return true
    }

    /// Records a frame; labelled only during the settled part of a hold.
    public mutating func record(_ obs: FrameObservation, at now: Double) {
        guard !finished else { return }
        let labelled = pausedAt == nil && phase == .hold && now - phaseStart >= settle
        frames.append((stepIndex, LabeledFrame(label: labelled ? reactions[stepIndex] : nil, observation: obs)))
    }

    public mutating func togglePause(_ now: Double) {
        if let p = pausedAt {
            phaseStart += now - p  // resume where we left off
            pausedAt = nil
        } else {
            pausedAt = now
        }
    }

    /// Skips the current reaction (its frames are dropped from the labels).
    public mutating func skip(_ now: Double) {
        relabel(step: stepIndex)
        pausedAt = nil
        phaseStart = now
        _ = advanceStep()
    }

    /// Goes back one reaction and records it again.
    public mutating func redoPrevious(_ now: Double) {
        relabel(step: stepIndex)
        stepIndex = max(0, phase == .prepare ? stepIndex - 1 : stepIndex)
        relabel(step: stepIndex)
        phase = .prepare
        pausedAt = nil
        phaseStart = now
    }

    private mutating func relabel(step: Int) {
        for i in frames.indices where frames[i].step == step { frames[i].frame.label = nil }
    }

    public func recording(camera: String) -> Recording {
        Recording(camera: camera, frames: frames.map(\.frame))
    }
}
