import Foundation

/// How a meme enters and leaves the picture in quiet mode.
public enum PopStyle: String, Sendable, CaseIterable, Identifiable {
    /// Sticker card that springs in (scale 0.6 → 1.08 → 1, −6° → 0°) and shrinks away.
    case pop
    /// Card slides in from the nearest edge and back out.
    case slide
    /// Plain crossfade between camera-only and the layout.
    case fade

    public var id: String { rawValue }
}

/// Where the meme card is at one instant of its appear / disappear animation.
public struct PopPose: Sendable, Equatable {
    public var scale: Double
    /// Degrees, counter-clockwise positive.
    public var rotation: Double
    /// 0 = in place, 1 = fully off screen towards the nearest edge (slide).
    public var travel: Double
    public var opacity: Double

    public init(scale: Double = 1, rotation: Double = 0, travel: Double = 0, opacity: Double = 1) {
        self.scale = scale
        self.rotation = rotation
        self.travel = travel
        self.opacity = opacity
    }

    public static let rest = PopPose()
}

/// Time-based pop-up animation curves. Pure functions so they can be unit-tested and evaluated per frame
/// without state: the pipeline feeds a linear progress 0…1 of the current phase.
public enum PopAnimation {
    /// Seconds an appear (`appearing == true`) or disappear phase lasts.
    public static func duration(_ style: PopStyle, appearing: Bool) -> Double {
        switch style {
        case .pop: appearing ? 0.6 : 0.22
        case .slide: appearing ? 0.45 : 0.3
        case .fade: 0.25
        }
    }

    /// Analytic damped-spring step response, normalised to t ∈ 0…1: starts at 0, overshoots by about
    /// `overshoot` (first peak at t ≈ 0.4), and is exactly 1 at t = 1 (the tiny leftover oscillation is
    /// windowed out near the end so the card never "snaps").
    public static func spring(_ t: Double, overshoot: Double = 0.08) -> Double {
        guard t > 0 else { return 0 }
        guard t < 1 else { return 1 }
        let lnOS = log(max(1e-4, min(overshoot, 0.9)))
        // Damping ratio for the requested overshoot of an underdamped 2nd-order system.
        let zeta = -lnOS / (Double.pi * Double.pi + lnOS * lnOS).squareRoot()
        let damped = Double.pi / 0.4                       // first peak at t = 0.4
        let omega = damped / (1 - zeta * zeta).squareRoot()
        let decay = exp(-zeta * omega * t)
        let residual = decay * (cos(damped * t) + zeta * omega / damped * sin(damped * t))
        return 1 - residual * (1 - pow(t, 6))
    }

    public static func easeOutCubic(_ t: Double) -> Double { let u = 1 - clamp(t); return 1 - u * u * u }
    public static func easeInCubic(_ t: Double) -> Double { let u = clamp(t); return u * u * u }
    public static func smoothstep(_ t: Double) -> Double { let u = clamp(t); return u * u * (3 - 2 * u) }

    /// Pose at `progress` (linear 0…1) of the appear or disappear phase.
    public static func pose(_ style: PopStyle, progress: Double, appearing: Bool) -> PopPose {
        let t = clamp(progress)
        return switch (style, appearing) {
        case (.pop, true):
            // Scale 0.6 → 1.08 → 1 (a livelier spring than the rotation), quick fade-in so the small
            // card doesn't blink into existence.
            PopPose(scale: 0.6 + 0.4 * spring(t, overshoot: 0.2),
                    rotation: -6 * (1 - spring(t)),
                    opacity: smoothstep(t / 0.25))
        case (.pop, false):
            PopPose(scale: 1 - 0.3 * easeInCubic(t), rotation: 4 * easeInCubic(t),
                    opacity: 1 - smoothstep(t))
        case (.slide, true):
            PopPose(travel: 1 - easeOutCubic(t))
        case (.slide, false):
            PopPose(travel: easeInCubic(t))
        case (.fade, true):
            PopPose(opacity: t)
        case (.fade, false):
            PopPose(opacity: 1 - t)
        }
    }

    private static func clamp(_ t: Double) -> Double { min(1, max(0, t)) }
}
