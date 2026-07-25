import Foundation
import ZephyrFlowCore

/// On-device **enhanced** Flow backend (deterministic rules — not an LLM).
///
/// Routed only for Professional / Bullets / Summary via `FlowRouter`.
/// Clean / Raw never use this path. No network. No model weights.
/// Honors `Task` cancellation so router timeouts can unwind.
actor NeuralFlowProcessor: FlowProcessorProtocol {
    static let shared = NeuralFlowProcessor()

    private(set) var isReady = false
    private let regex = FlowProcessor.shared

    var meetsRAMGate: Bool {
        // Light CPU work only — no large model. Gate kept modest so Auto isn't blocked
        // on small machines for a rules path.
        ProcessInfo.processInfo.physicalMemory >= 4 * 1024 * 1024 * 1024
    }

    func refreshAvailability() {
        isReady = meetsRAMGate
    }

    func process(_ text: String, style: FlowStyle) async -> String {
        refreshAvailability()
        guard isReady else {
            return await regex.process(text, style: style)
        }

        if Task.isCancelled {
            return await regex.process(text, style: style)
        }

        switch style {
        case .clean, .raw:
            return await regex.process(text, style: style)
        case .professional:
            return await enhancedProfessional(text)
        case .bullets:
            return await enhancedBullets(text)
        case .summary:
            return await enhancedSummary(text)
        }
    }

    // MARK: - Enhanced local rewrites (on-device, deterministic)

    private func enhancedProfessional(_ text: String) async -> String {
        var base = await regex.process(text, style: .professional)
        if Task.isCancelled { return base }
        let extras: [(String, String)] = [
            (#"(?i)\bcircle back\b"#, "follow up"),
            (#"(?i)\bloop in\b"#, "include"),
            (#"(?i)\bsync up\b"#, "meet"),
            (#"(?i)\btouch base\b"#, "connect"),
            (#"(?i)\bbusted\b"#, "broken"),
            (#"(?i)\bkinda\b"#, "somewhat"),
            (#"(?i)\blgtm\b"#, "looks good to me"),
        ]
        for (pat, rep) in extras {
            if Task.isCancelled { break }
            if let regex = try? NSRegularExpression(pattern: pat) {
                let range = NSRange(base.startIndex..., in: base)
                base = regex.stringByReplacingMatches(in: base, range: range, withTemplate: rep)
            }
        }
        base = base.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        return base.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func enhancedBullets(_ text: String) async -> String {
        let cleaned = await regex.process(text, style: .clean)
        if Task.isCancelled { return await regex.process(text, style: .bullets) }

        var parts = cleaned.components(separatedBy: CharacterSet(charactersIn: ".!;"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if parts.count <= 1 {
            let andSplit = cleaned
                .replacingOccurrences(of: #"\s+and\s+"#, with: "\u{1e}", options: .regularExpression)
                .split(separator: "\u{1e}")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if andSplit.count >= 2 {
                parts = andSplit
            }
        }

        if parts.count <= 1 {
            return await regex.process(text, style: .bullets)
        }

        return parts.map { part -> String in
            var p = part
            if let first = p.first {
                p = String(first).uppercased() + p.dropFirst()
            }
            return "• \(p)"
        }.joined(separator: "\n")
    }

    private func enhancedSummary(_ text: String) async -> String {
        let cleaned = await regex.process(text, style: .clean)
        if Task.isCancelled { return await regex.process(text, style: .summary) }

        let sentences = cleaned
            .components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard sentences.count > 2 else {
            return await regex.process(text, style: .summary)
        }

        let constraint = sentences.first {
            let l = $0.lowercased()
            return l.contains("not ") || l.contains("don't") || l.contains("do not")
                || l.contains("never") || l.contains("without")
        }
        let first = sentences[0]
        let rest = Array(sentences.dropFirst())
        let longest = rest.max(by: { $0.count < $1.count }) ?? ""

        if let constraint {
            let other = ([first] + rest).first { $0 != constraint && $0.count >= 12 } ?? longest
            let a = constraint.hasSuffix(".") ? constraint : constraint + "."
            let b = other.hasSuffix(".") ? other : other + "."
            return "\(a) \(b)"
        }

        return await regex.process(text, style: .summary)
    }
}
