import Foundation

/// Deterministic regex Flow rules (JOE-2277): language-aware, paragraph-
/// preserving, with protected technical spans and precompiled expressions.
/// English filler/contraction heuristics apply ONLY to qualified English
/// locales; other languages get whitespace/punctuation-safe behavior.
public actor FlowProcessor: FlowProcessorProtocol {
    public static let shared = FlowProcessor()

    public init() {}

    // MARK: - Precompiled regexes (no per-call compilation)

    private static let urlPattern = try? NSRegularExpression(pattern: #"https?://[^\s"'<>]+"#)
    private static let emailPattern = try? NSRegularExpression(pattern: #"[\w.+-]+@[\w-]+\.[\w.-]+"#)
    private static let pathPattern = try? NSRegularExpression(pattern: #"(?:/[A-Za-z0-9._-]+)+"#)
    private static let versionPattern = try? NSRegularExpression(pattern: #"\b\d+\.\d+(?:\.\d+)+\b"#)
    private static let abbreviationPattern = try? NSRegularExpression(pattern: #"\b[A-Z]{2,}\b"#)
    // Double-quoted spans and backtick code only; single quotes are NOT
    // treated as quoting because apostrophes in contractions (can't, it's)
    // must remain editable by the contraction rules.
    private static let quotedPattern = try? NSRegularExpression(pattern: #""[^"\n]*"#)
    private static let codePattern = try? NSRegularExpression(pattern: #"`[^`\n]*`"#)
    private static let fillerMulti = [
        "you know", "i mean", "sort of", "kind of", "okay so", "so yeah",
    ]
    private static let fillerSingle = ["um", "uh", "uhm", "erm", "ah", "eh"]

    public func process(_ text: String, style: FlowStyle) async -> String {
        await process(text, style: style, language: .auto)
    }

    /// JOE-2279: typed outcome for the deterministic rules backend.
    public func process(_ request: FlowRequest) async -> FlowOutcome {
        let started = Date()
        let output = await process(
            request.text, style: request.style,
            language: request.language)
        let duration = UInt64(Date().timeIntervalSince(started) * 1_000_000_000)
        let loss = FlowOutcome.lossClass(for: request.style)
        // Deterministic backend: guardrails already applied inside rules.
        let protectedSpanCount = FlowGuardrails.tokens(in: request.text).count
        let outTokens = FlowGuardrails.tokens(in: output)
        let protectedSpansPreserved = FlowGuardrails.inputCovered(
            input: FlowGuardrails.tokens(in: request.text),
            output: outTokens
        ).ok
        let changed = request.text != output ? 1 : 0
        // Review R2/9: a failed protected-span comparison must NEVER return
        // .accepted. Return the conservative fallback (the unmodified input
        // is the safest output) with a controlled rejection reason.
        let status: FlowOutcomeStatus = protectedSpansPreserved ? .accepted : .rejected
        let warnings: [FlowWarning] = protectedSpansPreserved ? [] : [.guardrailRejected]
        let fallbackReason: String? =
            protectedSpansPreserved
            ? nil
            : "protected spans not preserved; conservative output returned"
        return FlowOutcome(
            text: output,
            requestedStyle: request.style,
            resolvedLossClass: loss,
            backend: .regex,
            capabilityID: "io.zephyr-flow.flow.rules.v1",
            capabilityVersion: 1,
            language: request.language,
            changedRangeCount: changed,
            protectedSpanCount: protectedSpanCount,
            protectedSpansPreserved: protectedSpansPreserved,
            status: status,
            warnings: warnings,
            fallbackReason: fallbackReason,
            durationNanos: duration,
            termination: .completed)
    }

    public func process(
        _ text: String,
        style: FlowStyle,
        language: SupportedLanguage = .auto
    ) async -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        switch style {
        case .raw:
            return trimmed
        case .clean:
            return clean(trimmed, language: language)
        case .bullets:
            return toBullets(clean(trimmed, language: language))
        case .professional:
            return professional(clean(trimmed, language: language), language: language)
        case .summary:
            return summarize(clean(trimmed, language: language))
        }
    }

    // MARK: - Language qualification

    /// English heuristics apply only to qualified English locales; `auto`
    /// permits them (the product is English-first), fixed non-English locales
    /// receive whitespace/punctuation-safe behavior only.
    private func isEnglishQualified(_ language: SupportedLanguage) -> Bool {
        language.isAuto || (language.bcp47?.hasPrefix("en") ?? false)
    }

    // MARK: - Protected technical spans

    /// Extract URLs/emails/paths/versions/abbreviations/quoted/code spans into
    /// placeholders so sentence rules never alter them; restore afterwards.
    private func protect(_ text: String, startIndex: Int = 0) -> (protected: String, spans: [String]) {
        var protected = text
        var spans: [String] = []
        let patterns = [
            Self.urlPattern, Self.emailPattern, Self.pathPattern,
            Self.versionPattern, Self.quotedPattern, Self.codePattern,
            Self.abbreviationPattern,
        ]
        var all: [(NSRange, String)] = []
        for pattern in patterns {
            guard let pattern else { continue }
            let ns = NSRange(protected.startIndex..., in: protected)
            pattern.enumerateMatches(in: protected, range: ns) { match, _, _ in
                guard let match, let range = Range(match.range, in: protected) else { return }
                all.append((match.range, String(protected[range])))
            }
        }
        // Non-overlapping selection: sort ascending and greedily keep spans
        // that do not overlap a previously kept one (path-inside-URL, etc.).
        all.sort { $0.0.location < $1.0.location }
        var kept: [(NSRange, String)] = []
        var lastEnd = 0
        for (range, span) in all {
            if range.location >= lastEnd {
                kept.append((range, span))
                lastEnd = range.location + range.length
            }
        }
        // Apply from the end so earlier ranges stay valid. Tokens are offset
        // by startIndex so spans across lines/paragraphs never collide
        // (review R5.1): restore() maps each token to exactly one span.
        kept.sort { $0.0.location > $1.0.location }
        for (range, span) in kept {
            spans.append(span)
            let token = "\u{0}\(startIndex + spans.count - 1)\u{0}"
            if let r = Range(NSRange(location: range.location, length: range.length), in: protected) {
                protected.replaceSubrange(r, with: token)
            }
        }
        return (protected, spans)
    }

    private func restore(_ protected: String, spans: [String]) -> String {
        var result = protected
        for (idx, span) in spans.enumerated() {
            result = result.replacingOccurrences(
                of: "\u{0}\(idx)\u{0}", with: span)
        }
        return result
    }

    // MARK: - Clean (paragraph-preserving)

    private func clean(_ text: String, language: SupportedLanguage) -> String {
        let english = isEnglishQualified(language)
        // Preserve paragraph breaks: split on newlines, clean each line,
        // rejoin; collapse blank-line runs to a single blank line.
        let lines = text.components(separatedBy: "\n")
        var cleanedLines: [String] = []
        var allSpans: [String] = []
        var blankStreak = 0
        for rawLine in lines {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                blankStreak += 1
                if blankStreak == 1 { cleanedLines.append("") }
                continue
            }
            blankStreak = 0
            let (protected, spans) = protect(line, startIndex: allSpans.count)
            // Globally unique placeholders per line: protect() already offset
            // this line's token indices by the running count, so tokens never
            // collide across lines (review R5.1) and restore() maps each token
            // to exactly one span.
            allSpans.append(contentsOf: spans)
            line = protected
            line = line.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            if english {
                for filler in Self.fillerMulti {
                    let pattern = "\\b\(NSRegularExpression.escapedPattern(for: filler))\\b[,.]?"
                    line = line.replacingOccurrences(
                        of: pattern, with: "",
                        options: [.regularExpression, .caseInsensitive])
                }
                for filler in Self.fillerSingle {
                    let pattern = "\\b\(filler)\\b[,.]?"
                    line = line.replacingOccurrences(
                        of: pattern, with: "",
                        options: [.regularExpression, .caseInsensitive])
                }
            }
            line = line.replacingOccurrences(
                of: #"\s+([,.!?;:])"#, with: "$1",
                options: .regularExpression)
            // Filler removal can leave double spaces — collapse intra-line
            // only (paragraph newlines are preserved separately).
            line = line.replacingOccurrences(
                of: #"[ \t]{2,}"#, with: " ",
                options: .regularExpression)
            cleanedLines.append(line.trimmingCharacters(in: .whitespaces))
        }
        var result = cleanedLines.joined(separator: "\n")
        // Collapse 3+ newlines to a paragraph break.
        result = result.replacingOccurrences(
            of: "\n{3,}", with: "\n\n",
            options: .regularExpression)
        // Capitalize the placeholder-protected text, THEN restore spans so
        // sentence rules never alter protected content.
        result = capitalizeSentencesProtected(result)
        result = restore(result, spans: allSpans)
        if result.count > 12, let last = result.last, !".!?".contains(last) {
            result += "."
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Professional

    private func professional(_ text: String, language: SupportedLanguage) -> String {
        let english = isEnglishQualified(language)
        let (protected, spans) = protect(text)
        var result = protected

        // Ambiguous contractions are NOT forced to one meaning (JOE-2277):
        // I'd (would/had), it's (is/has), that's, there's are left intact.
        // Unambiguous expansions apply only for English locales.
        let replacements: [(String, String)] = [
            (#"\bcan't\b"#, "cannot"),
            (#"\bwon't\b"#, "will not"),
            (#"\bdon't\b"#, "do not"),
            (#"\bdidn't\b"#, "did not"),
            (#"\bisn't\b"#, "is not"),
            (#"\baren't\b"#, "are not"),
            (#"\bwasn't\b"#, "was not"),
            (#"\bweren't\b"#, "were not"),
            (#"\bhaven't\b"#, "have not"),
            (#"\bhasn't\b"#, "has not"),
            (#"\bhadn't\b"#, "had not"),
            (#"\bI'm\b"#, "I am"),
            (#"\bI've\b"#, "I have"),
            (#"\bI'll\b"#, "I will"),
            (#"\bwe're\b"#, "we are"),
            (#"\bwe've\b"#, "we have"),
            (#"\bwe'll\b"#, "we will"),
            (#"\bthey're\b"#, "they are"),
            (#"\bthey've\b"#, "they have"),
            (#"\bgonna\b"#, "going to"),
            (#"\bwanna\b"#, "want to"),
            (#"\bkinda\b"#, "kind of"),
            (#"\byeah\b"#, "yes"),
            (#"\byep\b"#, "yes"),
            (#"\bnope\b"#, "no"),
            (#"\bokay\b"#, "all right"),
            (#"\bok\b"#, "all right"),
            (#"\bhey\b"#, "hello"),
            (#"\basap\b"#, "as soon as possible"),
            (#"\bfyi\b"#, "for your information"),
        ]
        if english {
            for (pattern, replacement) in replacements {
                result = result.replacingOccurrences(
                    of: pattern, with: replacement,
                    options: [.regularExpression, .caseInsensitive])
            }
        }
        result = result.replacingOccurrences(
            of: #"\s{2,}"#, with: " ",
            options: .regularExpression)
        // Capitalize protected text, then restore technical spans.
        result = capitalizeSentencesProtected(result.trimmingCharacters(in: .whitespacesAndNewlines))
        return restore(result, spans: spans)
    }

    // MARK: - Bullets

    private func toBullets(_ text: String) -> String {
        var parts = splitSentences(text)
        if parts.count == 1 {
            let commas = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if commas.count >= 3 {
                parts = commas
            }
        }
        if parts.count <= 1 {
            return "• \(text)"
        }
        return
            parts
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".!?;: ")) }
            .filter { !$0.isEmpty }
            .map { "• \(capitalizeFirst($0))" }
            .joined(separator: "\n")
    }

    // MARK: - Summary

    /// Fact-preserving summary (JOE-2281): selects the first + longest
    /// sentences, then adds any sentence carrying a protected token (number/
    /// negation/identifier/…) not yet covered so critical facts are never
    /// dropped by the semantic path.
    private func summarize(_ text: String) -> String {
        let sentences = splitSentences(text)
        guard sentences.count > 2 else { return text }
        let first = sentences[0]
        let rest = Array(sentences.dropFirst())
        let longest = rest.max(by: { $0.count < $1.count }) ?? ""
        var selected = [first]
        if !longest.isEmpty && longest != first {
            selected.append(longest)
        }
        // Cover every protected token (facts) across the selected sentences.
        let inputTokens = Set(FlowGuardrails.tokens(in: text))
        var covered = Set(FlowGuardrails.tokens(in: selected.joined(separator: " ")))
        for sentence in rest where covered.count < inputTokens.count {
            let sentenceTokens = Set(FlowGuardrails.tokens(in: sentence))
            let newFacts = sentenceTokens.subtracting(covered)
            if !newFacts.isEmpty, !selected.contains(sentence) {
                selected.append(sentence)
                covered.formUnion(newFacts)
            }
        }
        return selected.joined(separator: " ")
    }

    // MARK: - Helpers

    private func splitSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: [.bySentences, .localized]) { sub, _, _, _ in
            if let s = sub?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                sentences.append(s)
            }
        }
        return sentences.isEmpty ? [text] : sentences
    }

    /// Unicode-safe sentence capitalization that skips protected placeholders.
    private func capitalizeSentencesProtected(_ text: String) -> String {
        var result = ""
        var capitalizeNext = true
        var idx = 0
        let chars = Array(text)
        while idx < chars.count {
            let ch = chars[idx]
            if ch == "\u{0}" {
                // Skip the whole placeholder token \u{0}N\u{0}.
                var end = idx + 1
                while end < chars.count, chars[end] != "\u{0}" { end += 1 }
                if end < chars.count { end += 1 }
                result.append(contentsOf: chars[idx..<end])
                idx = end
                continue
            }
            if capitalizeNext, ch.isLetter {
                result.append(contentsOf: String(ch).uppercased())
                capitalizeNext = false
            } else {
                result.append(ch)
                if ".!?".contains(ch) {
                    capitalizeNext = true
                }
            }
            idx += 1
        }
        return result
    }

    private func capitalizeFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return String(first).uppercased() + text.dropFirst()
    }
}
