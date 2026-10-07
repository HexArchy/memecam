import Foundation

public enum AppVersion {
    /// "v1.2.3" → "1.2.3".
    public static func normalize(_ tag: String) -> String {
        tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    /// Numeric dotted comparison: 1.0.10 > 1.0.9, 1.1 > 1.0.9, 1.0 == 1.0.0.
    public static func isNewer(_ a: String, than b: String) -> Bool {
        let x = normalize(a).split(separator: ".").map { Int($0) ?? 0 }
        let y = normalize(b).split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}
