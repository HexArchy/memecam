import Foundation

/// Where "Teach MemeCam" keeps its data, on this Mac only: the teach sessions (face and hand landmark
/// positions, no images) and the model built from them.
///
///     <directory>/sessions/<date>.json.lzfse   trimmed `Recording`s, LZFSE-compressed JSON
///     <directory>/model.json                   `PersonalModel` (absent when not accepted)
///     <directory>/report.json                  last `PersonalizationReport`
public struct PersonalStore: Sendable {
    public let directory: URL
    /// Older sessions beyond this are deleted (training only uses the newest takes anyway).
    static let maxSessions = 12

    public init(directory: URL) {
        self.directory = directory
    }

    private var sessionsDirectory: URL { directory.appending(path: "sessions", directoryHint: .isDirectory) }
    private var modelURL: URL { directory.appending(path: "model.json") }
    private var reportURL: URL { directory.appending(path: "report.json") }

    public func saveSession(_ recording: Recording) throws {
        try FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter.string(from: recording.createdAt, timeZone: .gmt,
                                                formatOptions: [.withInternetDateTime, .withFractionalSeconds])
            .replacingOccurrences(of: ":", with: "-")
        let data = try (Self.encoder.encode(Self.trimmed(recording)) as NSData).compressed(using: .lzfse) as Data
        try data.write(to: sessionsDirectory.appending(path: "\(stamp).json.lzfse"), options: .atomic)
        try prune()
    }

    /// Every saved session, oldest first. Unreadable files are skipped.
    public func sessions() -> [Recording] {
        sessionFiles().compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let json = try? (data as NSData).decompressed(using: .lzfse) as Data else { return nil }
            return try? Self.decoder.decode(Recording.self, from: json)
        }
    }

    public var hasSessions: Bool { !sessionFiles().isEmpty }

    /// Saves the model (nil removes it) and the report.
    public func save(model: PersonalModel?, report: PersonalizationReport) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let model {
            try Self.encoder.encode(model).write(to: modelURL, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: modelURL)
        }
        try Self.encoder.encode(report).write(to: reportURL, options: .atomic)
    }

    /// The stored model if it matches the current feature layout and hand model; nil otherwise.
    public func loadModel(handModelHash: String) -> PersonalModel? {
        guard let data = try? Data(contentsOf: modelURL),
              let model = try? Self.decoder.decode(PersonalModel.self, from: data),
              model.featureVersion == ReactionFeatures.version, model.handModelHash == handModelHash
        else { return nil }
        return model
    }

    public func loadReport() -> PersonalizationReport? {
        (try? Data(contentsOf: reportURL)).flatMap { try? Self.decoder.decode(PersonalizationReport.self, from: $0) }
    }

    /// Forgets everything that was taught.
    public func reset() throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    /// Only labelled frames plus 1 s before each labelled run (the classifier's smoothing and held hands
    /// need that lead-in); roughly halves a session.
    public static func trimmed(_ recording: Recording) -> Recording {
        let frames = recording.frames
        var keep = [Bool](repeating: false, count: frames.count)
        for i in frames.indices where frames[i].label != nil {
            keep[i] = true
            if i == 0 || frames[i - 1].label == nil {
                var j = i - 1
                while j >= 0, frames[i].observation.timestamp - frames[j].observation.timestamp <= 1 {
                    keep[j] = true
                    j -= 1
                }
            }
        }
        var out = recording
        out.frames = frames.indices.filter { keep[$0] }.map { frames[$0] }
        return out
    }

    private func sessionFiles() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: sessionsDirectory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasSuffix(".json.lzfse") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func prune() throws {
        for url in sessionFiles().dropLast(Self.maxSessions) { try FileManager.default.removeItem(at: url) }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
