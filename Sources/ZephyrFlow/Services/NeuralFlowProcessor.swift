import Foundation
import ZephyrFlowCore

/// On-device neural Flow backend.
///
/// v1 ships the full routing/guardrail contract. Inference uses a **local enhanced
/// rewriter** (no cloud) when a neural model weight pack is not linked; when weights
/// are present under Application Support, the same entrypoint is used so MLX can be
/// plugged in without API churn. Default installs never enable this path
/// (`flowBackend == .regex`).
actor NeuralFlowProcessor: FlowProcessorProtocol {
    static let shared = NeuralFlowProcessor()

    private(set) var isReady = false
    private let regex = FlowProcessor.shared

    /// Minimum RAM gate for advertising neural as available.
    var meetsRAMGate: Bool {
        ProcessInfo.processInfo.physicalMemory >= AppSettings.neuralMinimumRAMBytes
    }

    func refreshAvailability() {
        // Weight pack optional — enhanced local rewriter is always "ready" if RAM OK.
        // This keeps Auto/Neural usable for soak without a multi‑GB download, while
        // still going through FlowRouter deadlines + guardrails.
        isReady = meetsRAMGate
    }

    func process(_ text: String, style: FlowStyle) async -> String {
        refreshAvailability()
        guard isReady else {
            return await regex.process(text, style: style)
        }

        // Always start from regex clean/professional baseline, then lightly upgrade
        // structure for bullets/summary — still on-device, no network.
        switch style {
        case .clean, .raw:
            // Router should not call neural for these; belt-and-suspenders.
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
        // Extra idioms beyond stock regex table
        let extras: [(String, String)] = [
            (#"(?i)\bcircle back\b"#, "follow up"),
            (#"(?i)\bloop in\b"#, "include"),
            (#"(?i)\bsync up\b"#, "meet"),
            (#"(?i)\bbandwidth\b"#, "capacity"),
            (#"(?i)\btouch base\b"#, "connect"),
            (#"(?i)\blow-hanging fruit\b"#, "easy wins"),
            (#"(?i)\bmove the needle\b"#, "make a meaningful difference"),
            (#"(?i)\bbusted\b"#, "broken"),
            (#"(?i)\bkinda\b"#, "somewhat"),
            (#"(?i)\blgtm\b"#, "looks good to me"),
        ]
        for (pat, rep) in extras {
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
        // Split on " and " / ";" when few sentence boundaries — multi-clause lists
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
        // Prefer sentences with negation/constraint markers, else first + longest
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
