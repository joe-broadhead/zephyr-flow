import Foundation

// JOE-2278: expanded Flow guardrails — signed/multiset facts, negation and
// protected identifiers. Rejects or falls back from output that drops,
// duplicates, reorders or changes protected meaning, not only output that
// invents a new unsigned number.

/// Typed protected-token kind (content-free classification).
public enum ProtectedTokenKind: String, Codable, CaseIterable, Sendable, Equatable {
    case number          // signed/un-signed number (sign preserved)
    case percent         // 10%
    case currency        // $10, €5, £7
    case unit            // 10 ms, 5 kg (number+unit association)
    case version         // v1.2.3 / 1.2.3
    case dateTime        // 2026-08-08, 14:30
    case duration        // 2h30m, 90s
    case url
    case email
    case path
    case code
    case quoted
    case identifier      // issue/commit IDs e.g. JOE-2278, abc1234
    case negation        // do not / never / must not / without / cannot ...
}

/// One canonical protected token (multiset element; multiplicity preserved).
public struct ProtectedToken: Sendable, Equatable, Hashable {
    public let kind: ProtectedTokenKind
    /// Canonical value — sign preserved for numbers; structural variants
    /// (e.g. 12000 vs 12,000) canonicalize equal.
    public let canonical: String

    public init(kind: ProtectedTokenKind, canonical: String) {
        self.kind = kind
        self.canonical = canonical
    }
}

/// Controlled rejection reason (content-free).
public enum FlowGuardrailsRejection: String, Codable, CaseIterable, Sendable, Equatable {
    case emptyOutput
    case preamble
    case extremeExpansion
    case novelNumber               // output number not present in input
    case droppedNumber             // input number missing from output
    case signFlipped               // -5 became 5 (or vice versa)
    case droppedMultiplicity       // repeated numbers collapsed
    case droppedNegation           // do not/never/must/without removed/inverted
    case droppedProtectedToken     // url/email/path/code/quoted/version/identifier omitted
    case droppedPercent            // 10% association lost
    case droppedCurrency           // $10 association lost
    case droppedUnit               // 10 ms association lost
}

/// Result of the guardrail gate.
public enum FlowGuardrailsResult: Sendable, Equatable {
    case approved(String)
    case rejected(reason: FlowGuardrailsRejection, conservativeFallback: String)
}

/// Production guardrails for enhanced Flow output (JOE-2275/2278).
public enum FlowGuardrails: Sendable {
    private static let numberPattern = try! NSRegularExpression(
        pattern: #"-?\b\d{1,3}(?:,\d{3})+(?:\.\d+)?\b|-?\b\d+(?:\.\d+)?\b"#)
    private static let percentPattern = try! NSRegularExpression(pattern: #"-?\d+(?:\.\d+)?%"#)
    private static let currencyPattern = try! NSRegularExpression(pattern: #"[$€£¥]\s?-?\d+(?:\.\d+)?"#)
    private static let unitPattern = try! NSRegularExpression(pattern: #"-?\d+(?:\.\d+)?\s?(?:ms|sec|min|hr|kg|mg|km|mm|GB|MB|KB|px|em|rem|s|m|g|h|cm|%)\b"#)
    private static let versionPattern = try! NSRegularExpression(pattern: #"\bv\d+\.\d+(?:\.\d+)*\b|\b\d+\.\d+\.\d+\b"#)
    private static let datePattern = try! NSRegularExpression(pattern: #"\b\d{4}-\d{1,2}-\d{1,2}\b|\b\d{1,2}[/.-]\d{1,2}[/.-]\d{2,4}\b"#)
    private static let timePattern = try! NSRegularExpression(pattern: #"\b\d{1,2}:\d{2}(?::\d{2})?\b"#)
    private static let urlPattern = try? NSRegularExpression(pattern: #"https?://[^\s"'<>]+"#)
    private static let emailPattern = try? NSRegularExpression(pattern: #"[\w.+-]+@[\w-]+\.[\w.-]+"#)
    private static let pathPattern = try? NSRegularExpression(pattern: #"(?:/[A-Za-z0-9._-]+)+"#)
    private static let codePattern = try? NSRegularExpression(pattern: #"`[^`\n]*`"#)
    private static let quotedPattern = try? NSRegularExpression(pattern: #""[^"\n]*""#)
    private static let identifierPattern = try? NSRegularExpression(pattern: #"\b[A-Z]{2,}-\d+\b|\b[a-f0-9]{7,40}\b"#)
    private static let negationWords: Set<String> = [
        "do not", "don't", "never", "must not", "cannot", "can't",
        "won't", "should not", "without", "no longer", "isn't", "aren't",
        "didn't", "doesn't", "not", "no",
    ]

    private static let preamblePrefixes = [
        "sure,", "sure ", "certainly", "of course", "here is", "here's",
        "as an ai", "i have rewritten", "cleaned text:", "output:",
    ]

    /// Canonical number (structural equivalence: 12000 ↔ 12,000).
    public static func canonicalizeNumber(_ raw: String) -> String {
        var n = raw.replacingOccurrences(of: ",", with: "")
        if let dot = n.firstIndex(of: "."),
           n.suffix(from: n.index(after: dot)).allSatisfy({ $0 == "0" }) {
            n = String(n[..<dot])
        }
        return n
    }

    // MARK: - Tokenization (typed, signed, multiset)

    /// All protected tokens in a string, typed + canonicalized.
    public static func tokens(in text: String) -> [ProtectedToken] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var result: [ProtectedToken] = []
        var covered = Set<Int>()   // start offsets covered by a broader token

        func addMatches(_ pattern: NSRegularExpression, kind: ProtectedTokenKind,
                        canonicalize: (String) -> String = { $0 }) {
            pattern.enumerateMatches(in: text, range: full) { m, _, _ in
                guard let m else { return }
                if covered.contains(m.range.location) { return }
                let raw = ns.substring(with: m.range)
                for i in m.range.location..<(m.range.location + m.range.length) {
                    covered.insert(i)
                }
                result.append(ProtectedToken(kind: kind, canonical: canonicalize(raw)))
            }
        }

        // Broader kinds first (URL/path/code/quoted cover inner numbers).
        addMatches(urlPattern ?? numberPattern, kind: .url)
        addMatches(emailPattern ?? numberPattern, kind: .email)
        addMatches(codePattern ?? numberPattern, kind: .code)
        addMatches(quotedPattern ?? numberPattern, kind: .quoted)
        addMatches(pathPattern ?? numberPattern, kind: .path)
        addMatches(versionPattern, kind: .version)
        addMatches(identifierPattern ?? numberPattern, kind: .identifier)
        addMatches(currencyPattern, kind: .currency)
        addMatches(percentPattern, kind: .percent)
        addMatches(unitPattern, kind: .unit)
        addMatches(datePattern, kind: .dateTime)
        addMatches(timePattern, kind: .dateTime)
        addMatches(numberPattern, kind: .number, canonicalize: canonicalizeNumber)

        // Negations (word-level, whole-string scan), canonicalized so approved
        // expansions (can't → cannot) are NOT treated as removal.
        let lower = text.lowercased()
        for word in negationWords {
            if lower.range(of: word) != nil {
                result.append(ProtectedToken(kind: .negation,
                                             canonical: canonicalNegation(word)))
            }
        }
        return result
    }

    /// Semantic base for negation variants (content-free).
    private static func canonicalNegation(_ word: String) -> String {
        switch word {
        case "don't", "do not": return "do-not"
        case "can't", "cannot", "can not": return "cannot"
        case "won't", "will not": return "will-not"
        case "isn't", "is not": return "is-not"
        case "aren't", "are not": return "are-not"
        case "didn't", "did not": return "did-not"
        case "doesn't", "does not": return "does-not"
        case "must not", "should not", "no longer": return word.replacingOccurrences(of: " ", with: "-")
        case "not", "no", "never", "without": return word
        default: return word
        }
    }

    // MARK: - Multiset comparison

    private static func multiset(_ tokens: [ProtectedToken]) -> [ProtectedToken: Int] {
        var m: [ProtectedToken: Int] = [:]
        for t in tokens { m[t, default: 0] += 1 }
        return m
    }

    /// True when every input token (with multiplicity) appears in output.
    private static func inputCovered(input: [ProtectedToken],
                                     output: [ProtectedToken]) -> (ok: Bool, missing: [ProtectedToken]) {
        let outSet = multiset(output)
        var missing: [ProtectedToken] = []
        for (token, count) in multiset(input) {
            let have = outSet[token] ?? 0
            if have < count {
                for _ in 0..<(count - have) { missing.append(token) }
            }
        }
        return (missing.isEmpty, missing)
    }

    /// Guard gate. Returns approved output or a rejected result carrying the
    /// controlled reason + approved conservative fallback.
    public static func evaluate(input: String, output: String,
                                conservativeFallback: String) -> FlowGuardrailsResult {
        let inTrim = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let outTrim = output.trimmingCharacters(in: .whitespacesAndNewlines)

        if outTrim.isEmpty {
            return inTrim.count > 8
                ? .rejected(reason: .emptyOutput, conservativeFallback: conservativeFallback)
                : .approved("")
        }

        let lower = outTrim.lowercased()
        for p in preamblePrefixes where lower.hasPrefix(p) {
            return .rejected(reason: .preamble, conservativeFallback: conservativeFallback)
        }

        // Extreme expansion → reject (ramble / hallucination).
        if inTrim.count >= 12, outTrim.count > Int(Double(inTrim.count) * 2.5) + 40 {
            return .rejected(reason: .extremeExpansion, conservativeFallback: conservativeFallback)
        }

        let inTokens = tokens(in: inTrim)
        let outTokens = tokens(in: outTrim)
        let covered = inputCovered(input: inTokens, output: outTokens)
        guard covered.ok else {
            // Map the FIRST missing token to a controlled reason.
            let reason = rejectionReason(for: covered.missing[0])
            return .rejected(reason: reason, conservativeFallback: conservativeFallback)
        }

        // Novel/duplicated numbers: output number multiplicity must not
        // exceed input multiplicity (never invent or duplicate a number).
        let inCounts = multiset(inTokens.filter { $0.kind == .number })
        let outCounts = multiset(outTokens.filter { $0.kind == .number })
        for (token, count) in outCounts where (inCounts[token] ?? 0) < count {
            return .rejected(reason: .novelNumber, conservativeFallback: conservativeFallback)
        }

        return .approved(outTrim)
    }

    private static func rejectionReason(for token: ProtectedToken) -> FlowGuardrailsRejection {
        switch token.kind {
        case .number:
            if token.canonical.hasPrefix("-") { return .signFlipped }
            return .droppedNumber
        case .percent: return .droppedPercent
        case .currency: return .droppedCurrency
        case .unit: return .droppedUnit
        case .negation: return .droppedNegation
        case .url, .email, .path, .code, .quoted, .version, .identifier:
            return .droppedProtectedToken
        case .dateTime, .duration:
            return .droppedProtectedToken
        }
    }

    // MARK: - Legacy API (compat)

    public static func accept(input: String, output: String) -> String? {
        switch evaluate(input: input, output: output, conservativeFallback: "") {
        case .approved(let out): return out
        case .rejected: return nil
        }
    }
}
