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
        case .neutral: "Neutral"
        case .smile: "Smile"
        case .laugh: "Laugh"
        case .surprised: "Surprised"
        case .eyebrowsRaised: "Eyebrows Up"
        case .eyesClosed: "Eyes Closed"
        case .sad: "Sad"
        case .headTilt: "Head Tilt"
        case .thumbsUp: "Thumbs Up"
        case .thumbsDown: "Thumbs Down"
        case .peace: "Peace"
        case .openPalm: "Open Palm"
        case .pointing: "Pointing"
        case .fist: "Fist"
        case .handsUp: "Hands Up"
        case .facepalm: "Facepalm"
        case .thinking: "Thinking"
        case .heart: "Heart"
        case .noFace: "Nobody Here"
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
