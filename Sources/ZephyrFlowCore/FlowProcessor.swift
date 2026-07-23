import Foundation

public actor FlowProcessor: FlowProcessorProtocol {
    public static let shared = FlowProcessor()

    public init() {}

    public func process(_ text: String, style: FlowStyle) async -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        switch style {
        case .raw:
            return trimmed
        case .clean:
            return clean(trimmed)
        case .bullets:
            return toBullets(clean(trimmed))
        case .professional:
            return professional(clean(trimmed))
        case .summary:
            return summarize(clean(trimmed))
        }
    }

    // MARK: - Clean

    private func clean(_ text: String) -> String {
        var result = text

        result = result.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)

        let multiWordFillers = ["you know", "i mean", "sort of", "kind of", "okay so", "so yeah"]
        for filler in multiWordFillers {
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: filler))\\b[,.]?"
            result = result.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }

        let singleFillers = ["um", "uh", "uhm", "erm", "ah", "eh"]
        for filler in singleFillers {
            let pattern = "\\b\(filler)\\b[,.]?"
            result = result.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }

        result = result.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: "\\s+([,.!?;:])", with: "$1", options: .regularExpression)
        result = capitalizeSentences(result.trimmingCharacters(in: .whitespacesAndNewlines))

        if result.count > 12, let last = result.last, !".!?".contains(last) {
            result += "."
        }

        return result
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

        return parts
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".!?;: ")) }
            .filter { !$0.isEmpty }
            .map { "• \(capitalizeFirst($0))" }
            .joined(separator: "\n")
    }

    // MARK: - Professional

    private func professional(_ text: String) -> String {
        var result = text

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
            (#"\bI'd\b"#, "I would"),
            (#"\bwe're\b"#, "we are"),
            (#"\bwe've\b"#, "we have"),
            (#"\bwe'll\b"#, "we will"),
            (#"\bthey're\b"#, "they are"),
            (#"\bthey've\b"#, "they have"),
            (#"\bit's\b"#, "it is"),
            (#"\bthat's\b"#, "that is"),
            (#"\bthere's\b"#, "there is"),
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

        for (pattern, replacement) in replacements {
            result = result.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: [.regularExpression, .caseInsensitive]
            )
        }

        result = result.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
        return capitalizeSentences(result.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Summary

    private func summarize(_ text: String) -> String {
        let sentences = splitSentences(text)
        guard sentences.count > 2 else { return text }

        let first = sentences[0]
        let rest = Array(sentences.dropFirst())
        let longest = rest.max(by: { $0.count < $1.count }) ?? ""
        if longest.isEmpty || longest == first {
            return first
        }
        return "\(first) \(longest)"
    }

    // MARK: - Helpers

    private func splitSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: [.bySentences, .localized]) { sub, _, _, _ in
            if let s = sub?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                sentences.append(s)
            }
        }
        if sentences.isEmpty { return [text] }
        return sentences
    }

    private func capitalizeSentences(_ text: String) -> String {
        var result = ""
        var capitalizeNext = true
        for ch in text {
            if capitalizeNext, ch.isLetter {
                result.append(contentsOf: String(ch).uppercased())
                capitalizeNext = false
            } else {
                result.append(ch)
                if ".!?".contains(ch) {
                    capitalizeNext = true
                }
            }
        }
        return result
    }

    private func capitalizeFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return String(first).uppercased() + text.dropFirst()
    }
}
