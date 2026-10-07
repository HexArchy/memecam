import Foundation

// Shared by the app and the camera extension: scripts/build-app.sh compiles this file into the extension
// too, so the extension's format list and the app's output sizes can't drift apart. Foundation only.

/// Output resolution of the virtual camera (and the preview).
public enum OutputResolution: String, CaseIterable, Codable, Sendable, Identifiable {
    case hd720, hd1080
    public var id: String { rawValue }
    public var height: Int { self == .hd720 ? 720 : 1080 }
}

/// Output aspect ratio of the virtual camera.
public enum OutputAspect: String, CaseIterable, Codable, Sendable, Identifiable {
    /// 16:9, what every call app expects by default.
    case wide
    /// 4:3, the classic webcam frame (Telegram, older apps show it without bars).
    case standard
    /// 1:1, round/square video messages.
    case square
    public var id: String { rawValue }

    /// Width for a given height.
    func width(height: Int) -> Int {
        switch self {
        case .wide: height * 16 / 9
        case .standard: height * 4 / 3
        case .square: height
        }
    }
}

public struct OutputFormat: Hashable, Codable, Sendable {
    public var resolution: OutputResolution
    public var aspect: OutputAspect

    public init(resolution: OutputResolution = .hd720, aspect: OutputAspect = .wide) {
        self.resolution = resolution
        self.aspect = aspect
    }

    public static let `default` = OutputFormat()

    /// Every format the camera offers, in the extension's format-index order (index 0 is the default).
    public static let all: [OutputFormat] = OutputAspect.allCases.flatMap { aspect in
        OutputResolution.allCases.map { OutputFormat(resolution: $0, aspect: aspect) }
    }

    public var width: Int { aspect.width(height: resolution.height) }
    public var height: Int { resolution.height }

    /// Layouts are designed on a canvas 720 px high; 1080p renders that canvas scaled ×1.5, so margins,
    /// bubbles and captions keep their proportions at every size.
    public static let designHeight = 720
    public var designWidth: Int { aspect.width(height: Self.designHeight) }
    public var scale: Double { Double(height) / Double(Self.designHeight) }

    public var index: Int { Self.all.firstIndex(of: self) ?? 0 }

    /// The format with exactly these pixel dimensions, if the camera offers one.
    public static func matching(width: Int, height: Int) -> OutputFormat? {
        all.first { $0.width == width && $0.height == height }
    }

    /// "1280×720".
    public var dimensions: String { "\(width)\u{00D7}\(height)" }
}
