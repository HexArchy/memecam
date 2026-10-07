import Foundation

/// A reaction the app can recognise. Raw values match `category` in `memes.json`.
public enum Reaction: String, CaseIterable, Codable, Sendable, Identifiable {
    // Face expressions
    case neutral, smile, laugh, surprised, eyebrowsRaised, eyesClosed, sad, headTilt
    // Single-hand gestures
    case thumbsUp, thumbsDown, peace, openPalm, pointing, fist
    // Hand + face / two-hand gestures
    case handsUp, facepalm, thinking, heart
    // Nobody in frame
    case noFace

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .neutral: String(localized: "Neutral", bundle: .main)
        case .smile: String(localized: "Smile", bundle: .main)
        case .laugh: String(localized: "Laugh", bundle: .main)
        case .surprised: String(localized: "Surprised", bundle: .main)
        case .eyebrowsRaised: String(localized: "Eyebrows Up", bundle: .main)
        case .eyesClosed: String(localized: "Eyes Closed", bundle: .main)
        case .sad: String(localized: "Sad", bundle: .main)
        case .headTilt: String(localized: "Head Tilt", bundle: .main)
        case .thumbsUp: String(localized: "Thumbs Up", bundle: .main)
        case .thumbsDown: String(localized: "Thumbs Down", bundle: .main)
        case .peace: String(localized: "Peace", bundle: .main)
        case .openPalm: String(localized: "Open Palm", bundle: .main)
        case .pointing: String(localized: "Pointing", bundle: .main)
        case .fist: String(localized: "Fist", bundle: .main)
        case .handsUp: String(localized: "Hands Up", bundle: .main)
        case .facepalm: String(localized: "Facepalm", bundle: .main)
        case .thinking: String(localized: "Thinking", bundle: .main)
        case .heart: String(localized: "Heart", bundle: .main)
        case .noFace: String(localized: "Nobody Here", bundle: .main)
        }
    }

    /// SF Symbol shown next to the reaction in the UI.
    public var symbol: String {
        switch self {
        case .neutral: "face.dashed"
        case .smile: "face.smiling"
        case .laugh: "face.smiling.inverse"
        case .surprised: "exclamationmark.bubble"
        case .eyebrowsRaised: "questionmark.bubble"
        case .eyesClosed: "moon.zzz"
        case .sad: "cloud.rain"
        case .headTilt: "rotate.left"
        case .thumbsUp: "hand.thumbsup"
        case .thumbsDown: "hand.thumbsdown"
        case .peace: "hand.peace" // falls back in UI if missing
        case .openPalm: "hand.raised"
        case .pointing: "hand.point.up.left"
        case .fist: "hand.raised.fingers.spread"
        case .handsUp: "figure.arms.open"
        case .facepalm: "person.crop.circle.badge.xmark"
        case .thinking: "brain.head.profile"
        case .heart: "heart"
        case .noFace: "person.slash"
        }
    }

    public var isGesture: Bool {
        switch self {
        case .thumbsUp, .thumbsDown, .peace, .openPalm, .pointing, .fist,
             .handsUp, .facepalm, .thinking, .heart: true
        default: false
        }
    }
}
