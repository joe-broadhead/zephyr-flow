import Foundation

/// Semantic version helpers (major.minor.patch[+/-suffix ignored for ordering).
public enum AppVersion: Sendable {
    /// Parse `"1.2.3"`, `"v1.2.3"`, `"1.2.3-beta"` → `(1,2,3)`.
    public static func parse(_ raw: String) -> (Int, Int, Int)? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("v") {
            s = String(s.dropFirst())
        }
        // Drop pre-release / build metadata for numeric compare
        if let cut = s.firstIndex(where: { $0 == "-" || $0 == "+" }) {
            s = String(s[..<cut])
        }
        let parts = s.split(separator: ".").map(String.init)
        guard parts.count >= 1, parts.count <= 3 else { return nil }
        let nums = parts.compactMap { Int($0) }
        guard nums.count == parts.count else { return nil }
        let major = nums[0]
        let minor = nums.count > 1 ? nums[1] : 0
        let patch = nums.count > 2 ? nums[2] : 0
        return (major, minor, patch)
    }

    /// True if `candidate` is strictly newer than `current`.
    public static func isNewer(candidate: String, than current: String) -> Bool {
        guard let c = parse(candidate), let cur = parse(current) else { return false }
        if c.0 != cur.0 { return c.0 > cur.0 }
        if c.1 != cur.1 { return c.1 > cur.1 }
        return c.2 > cur.2
    }
}
