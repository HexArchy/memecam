import AppKit
import MemeCamCore

extension Reaction {
    /// `symbol`, or a safe fallback when that SF Symbol doesn't exist on this macOS version.
    var displaySymbol: String { Self.resolvedSymbols[self] ?? "face.smiling" }

    private static let resolvedSymbols: [Reaction: String] = Dictionary(uniqueKeysWithValues: allCases.map { r in
        let ok = NSImage(systemSymbolName: r.symbol, accessibilityDescription: nil) != nil
        return (r, ok ? r.symbol : (r.isGesture ? "hand.raised" : "face.smiling"))
    })
}
