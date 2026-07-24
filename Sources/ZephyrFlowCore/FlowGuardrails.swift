import Foundation

/// Production mirror of eval number/fact gates for neural Flow output.
public enum FlowGuardrails: Sendable {
    private static let numberPattern = try! NSRegularExpression(
        pattern: #"\b\d{1,3}(?:,\d{3})+(?:\.\d+)?\b|\b\d+(?:\.\d+)?\b"#
    )

    private static let preamblePrefixes = [
        "sure,", "sure ", "certainly", "of course", "here is", "here's",
        "as an ai", "i have rewritten", "cleaned text:", "output:",
    ]

    public static func canonicalNumbers(in text: String) -> Set<String> {
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        let matches = numberPattern.matches(in: text, range: range)
        var out = Set<String>()
        for m in matches {
            let raw = ns.substring(with: m.range)
            out.insert(canonicalizeNumber(raw))
        }
        return out
    }

    public static func canonicalizeNumber(_ raw: String) -> String {
        var n = raw.replacingOccurrences(of: ",", with: "")
        if let dot = n.firstIndex(of: "."), n.suffix(from: n.index(after: dot)).allSatisfy({ $0 == "0" }) {
            n = String(n[..<dot])
        }
        return n
    }

    /// Returns nil if output should be rejected (caller falls back to regex).
    public static func accept(input: String, output: String) -> String? {
        let inTrim = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let outTrim = output.trimmingCharacters(in: .whitespacesAndNewlines)

        if outTrim.isEmpty {
            return inTrim.count > 8 ? nil : ""
        }

        let lower = outTrim.lowercased()
        for p in preamblePrefixes {
            if lower.hasPrefix(p) { return nil }
        }

        let inNums = canonicalNumbers(in: inTrim)
        let outNums = canonicalNumbers(in: outTrim)
        if !outNums.isSubset(of: inNums) {
            return nil
        }

        // Extreme expansion → reject (likely ramble / hallucination)
        if inTrim.count >= 12, outTrim.count > Int(Double(inTrim.count) * 2.5) + 40 {
            return nil
        }

        return outTrim
    }
}
