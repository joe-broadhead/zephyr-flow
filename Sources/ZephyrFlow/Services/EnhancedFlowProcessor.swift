import Foundation
import ZephyrFlowCore

/// On-device **enhanced** Flow backend (deterministic rules — not an LLM).
///
/// Routed only for Professional / Bullets / Summary via `FlowRouter`.
/// Clean / Raw never use this path. No network. No model weights.
/// Honors `Task` cancellation so router timeouts can unwind.
actor EnhancedFlowProcessor: FlowProcessorProtocol {
    static let shared = EnhancedFlowProcessor()

    /// Deterministic rules backend: no model weights, no RAM gate.
    /// Measured envelope is tiny (< 32 MB); Auto selection is never blocked
    /// by memory for this path (JOE-2276).
    private(set) var isReady = true
    private let regex = FlowProcessor.shared

    /// Honest capability contract (JOE-2276). Future model/LLM backends
    /// declare a different capability and need an evidence gate.
    static let capability = FlowCapability.enhancedRules

    /// Kept for router wiring compatibility; the rules engine is always ready.
    func refreshAvailability() {
        isReady = true
    }

    func process(_ text: String, style: FlowStyle) async -> String {
        await process(text, style: style, language: .auto)
    }

    /// JOE-2279: typed outcome — guardrail rejection/fallback is visible to
    /// UI/metrics without payload text.
    func process(_ request: FlowRequest) async -> FlowOutcome {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let started = Date()
        let output = await process(
            request.text, style: request.style,
            language: request.language)
        let duration = UInt64(Date().timeIntervalSince(started) * 1_000_000_000)
        let loss = FlowOutcome.lossClass(for: request.style)
        let protectedSpanCount = FlowGuardrails.tokens(in: request.text).count
        // Evaluate guardrails on the enhanced output; fallback is explicit.
        let fallback = await regex.process(
            request.text, style: request.style,
            language: request.language)
        switch FlowGuardrails.evaluate(
            input: request.text, output: output,
            conservativeFallback: fallback)
        {
        case .approved(let out):
            return FlowOutcome(
                text: out,
                requestedStyle: request.style,
                resolvedLossClass: loss,
                backend: .enhanced,
                capabilityID: "io.zephyr-flow.flow.rules.v1",
                capabilityVersion: 1,
                language: request.language,
                changedRangeCount: request.text != out ? 1 : 0,
                protectedSpanCount: protectedSpanCount,
                protectedSpansPreserved: FlowGuardrails.inputCovered(
                    input: FlowGuardrails.tokens(in: request.text),
                    output: FlowGuardrails.tokens(in: out)
                ).ok,
                status: .accepted,
                warnings: [],
                fallbackReason: nil,
                durationNanos: duration,
                termination: .completed)
        case .rejected(let reason, let conservative):
            return FlowOutcome(
                text: conservative,
                requestedStyle: request.style,
                resolvedLossClass: loss,
                backend: .regex,
                capabilityID: "io.zephyr-flow.flow.rules.v1",
                capabilityVersion: 1,
                language: request.language,
                changedRangeCount: 1,
                protectedSpanCount: protectedSpanCount,
                protectedSpansPreserved: true,
                status: .rejected,
                warnings: [.guardrailRejected],
                fallbackReason: "guardrail rejection: \(reason.rawValue)",
                durationNanos: duration,
                termination: .completed)
        }
    }

    /// JOE-2277/2278: language-aware enhanced rules with guardrail gate.
    func process(_ text: String, style: FlowStyle, language: SupportedLanguage) async -> String {
        refreshAvailability()
        guard isReady else {
            return await regex.process(text, style: style, language: language)
        }

        if Task.isCancelled {
            return await regex.process(text, style: style, language: language)
        }

        switch style {
        case .clean, .raw:
            return await regex.process(text, style: style, language: language)
        case .professional:
            let enhanced = await enhancedProfessional(text, language: language)
            return await guardrail(text, enhanced, style: style, language: language)
        case .bullets:
            let enhanced = await enhancedBullets(text, language: language)
            return await guardrail(text, enhanced, style: style, language: language)
        case .summary:
            let enhanced = await enhancedSummary(text, language: language)
            return await guardrail(text, enhanced, style: style, language: language)
        }
    }

    /// JOE-2278: guardrail gate — on rejection return the approved
    /// conservative fallback (regex) with the controlled reason logged.
    private func guardrail(
        _ input: String, _ output: String,
        style: FlowStyle, language: SupportedLanguage
    ) async -> String {
        let fallback = await regex.process(input, style: style, language: language)
        switch FlowGuardrails.evaluate(
            input: input, output: output,
            conservativeFallback: fallback)
        {
        case .approved(let out):
            return out
        case .rejected(let reason, let conservative):
            ZFLog.info("Flow guardrail rejection reason=\(reason.rawValue) style=\(style.rawValue)")
            return conservative
        }
    }

    // MARK: - Enhanced local rewrites (on-device, deterministic)

    /// Precompiled English-only extras (JOE-2277: no per-call compilation;
    /// applied only for qualified English locales).
    private static let englishExtras: [(NSRegularExpression, String)] = {
        let pairs: [(String, String)] = [
            (#"(?i)\bcircle back\b"#, "follow up"),
            (#"(?i)\bloop in\b"#, "include"),
            (#"(?i)\bsync up\b"#, "meet"),
            (#"(?i)\btouch base\b"#, "connect"),
            (#"(?i)\bbusted\b"#, "broken"),
            (#"(?i)\bkinda\b"#, "somewhat"),
            (#"(?i)\blgtm\b"#, "looks good to me"),
        ]
        return pairs.compactMap { (pattern, rep) in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return (regex, rep)
        }
    }()

    private func enhancedProfessional(_ text: String, language: SupportedLanguage) async -> String {
        var base = await regex.process(text, style: .professional, language: language)
        if Task.isCancelled { return base }
        // English heuristics only for qualified English locales.
        let english = language.isAuto || (language.bcp47?.hasPrefix("en") ?? false)
        if english {
            for (regex, rep) in Self.englishExtras {
                if Task.isCancelled { break }
                let range = NSRange(base.startIndex..., in: base)
                base = regex.stringByReplacingMatches(in: base, range: range, withTemplate: rep)
            }
        }
        base = base.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        return base.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func enhancedBullets(_ text: String, language: SupportedLanguage) async -> String {
        let cleaned = await regex.process(text, style: .clean)
        if Task.isCancelled { return await regex.process(text, style: .bullets) }

        var parts = cleaned.components(separatedBy: CharacterSet(charactersIn: ".!;"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if parts.count <= 1 {
            let andSplit =
                cleaned
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

    private func enhancedSummary(_ text: String, language: SupportedLanguage) async -> String {
        let cleaned = await regex.process(text, style: .clean)
        if Task.isCancelled { return await regex.process(text, style: .summary) }

        let sentences =
            cleaned
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
