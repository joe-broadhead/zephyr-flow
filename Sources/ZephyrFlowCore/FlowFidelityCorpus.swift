import Foundation

// JOE-2280: versioned Flow fidelity corpus. License-clean, deterministic
// cases across every contract dimension; the differential harness (tests)
// runs every case against the rules backend, checks protected-span
// preservation, forbidden changes, determinism and golden output, and
// produces a structured evidence report.

public struct FlowFidelityCase: Sendable, Equatable {
    public let id: String
    public let category: String
    public let language: SupportedLanguage
    public let style: FlowStyle
    public let input: String
    /// Tokens that must NEVER appear in output (forbidden changes).
    public let forbiddenTokens: [String]
    /// Exact golden output where deterministic (nil = checks only).
    public let goldenOutput: String?

    public init(
        id: String, category: String, language: SupportedLanguage,
        style: FlowStyle, input: String,
        forbiddenTokens: [String] = [],
        goldenOutput: String? = nil
    ) {
        self.id = id
        self.category = category
        self.language = language
        self.style = style
        self.input = input
        self.forbiddenTokens = forbiddenTokens
        self.goldenOutput = goldenOutput
    }
}

/// Versioned corpus (bump on any case/rule change; tests assert the version).
public enum FlowFidelityCorpus {
    public static let version = 1

    public static let cases: [FlowFidelityCase] = [
        // ---- natural dictation: fillers, repairs, punctuation ----
        .init(
            id: "nat-001", category: "natural", language: .enUS, style: .clean,
            input: "um so we should like um meet on monday i mean tuesday",
            forbiddenTokens: ["um", "i mean"]),
        .init(
            id: "nat-002", category: "natural", language: .enUS, style: .professional,
            input: "i can't make it, but don't worry, we'll reschedule",
            forbiddenTokens: ["can't", "don't"]),
        // ---- numbers: signed/repeated/currency/percent/units/versions ----
        .init(
            id: "num-001", category: "numbers", language: .enUS, style: .professional,
            input: "the balance is -5 and the profit is 5",
            forbiddenTokens: []),
        .init(
            id: "num-002", category: "numbers", language: .enUS, style: .professional,
            input: "it costs $10 or maybe 10 percent, wait 10 ms total",
            forbiddenTokens: []),
        .init(
            id: "num-003", category: "numbers", language: .enUS, style: .clean,
            input: "release v1.2.3 today and v1.2.3 tomorrow",
            forbiddenTokens: []),
        .init(
            id: "num-004", category: "numbers", language: .enUS, style: .summary,
            input: "We sold 5 units in January and 5 units in February, plus 5 more in March.",
            forbiddenTokens: []),
        // ---- negation / constraints / modals ----
        .init(
            id: "neg-001", category: "negation", language: .enUS, style: .professional,
            input: "do not run the tests without reviewing the diff",
            forbiddenTokens: []),
        .init(
            id: "neg-002", category: "negation", language: .enUS, style: .professional,
            input: "you must never delete that file",
            forbiddenTokens: []),
        // ---- identifiers: names/products/issues/commits ----
        .init(
            id: "id-001", category: "identifiers", language: .enUS, style: .professional,
            input: "fix JOE-2280 and commit abc1234 now",
            forbiddenTokens: []),
        .init(
            id: "id-002", category: "identifiers", language: .enUS, style: .clean,
            input: "Zephyr Flow 2.0 ships next week",
            forbiddenTokens: []),
        // ---- urls / emails / paths / code ----
        .init(
            id: "tech-001", category: "technical", language: .enUS, style: .professional,
            input: "see https://example.com/a.b and mail dev@zephyr.io",
            forbiddenTokens: []),
        .init(
            id: "tech-002", category: "technical", language: .enUS, style: .clean,
            input: "run `/usr/local/bin/deploy.sh --force` now",
            forbiddenTokens: []),
        .init(
            id: "tech-003", category: "technical", language: .enUS, style: .professional,
            input: "quote \"never ship broken\" in the notes",
            forbiddenTokens: []),
        // ---- paragraph / list structure ----
        .init(
            id: "para-001", category: "paragraph", language: .enUS, style: .clean,
            input: "First paragraph.\n\nSecond paragraph with more detail.",
            forbiddenTokens: []),
        .init(
            id: "para-002", category: "paragraph", language: .enUS, style: .bullets,
            input: "We need to fix the bug, update the docs, and ship it.",
            forbiddenTokens: []),
        // ---- caution cases: financial/legal/medical ----
        .init(
            id: "fin-001", category: "caution", language: .enUS, style: .professional,
            input: "the refund is $1,200 not $12,000",
            forbiddenTokens: []),
        .init(
            id: "leg-001", category: "caution", language: .enUS, style: .professional,
            input: "the contract does not permit that without written consent",
            forbiddenTokens: []),
        .init(
            id: "med-001", category: "caution", language: .enUS, style: .professional,
            input: "take 10 mg twice daily and never exceed 30 mg",
            forbiddenTokens: []),
        // ---- non-English locales ----
        .init(
            id: "i18n-001", category: "i18n", language: .deDE, style: .clean,
            input: "ähm wir sollten das bitte morgen besprechen",
            forbiddenTokens: []),
        .init(
            id: "i18n-002", category: "i18n", language: .frFR, style: .professional,
            input: "je ne peux pas venir, mais nous nous verrons demain",
            forbiddenTokens: []),
        // ---- summary: multi-sentence inputs (real transformation) ----
        .init(
            id: "sum-001", category: "summary", language: .enUS, style: .summary,
            input:
                "The team shipped the release on Tuesday. It includes the new Flow rules and the guardrails. The build was green and we updated the docs. We did not skip the tests.",
            forbiddenTokens: []),
        .init(
            id: "sum-002", category: "summary", language: .enUS, style: .summary,
            input:
                "Revenue grew by 10 percent this quarter. Costs stayed flat at $5,000. We did not cut the engineering budget. The forecast for next quarter is 12 percent growth.",
            forbiddenTokens: []),
        // ---- edge: empty/short/long/adversarial ----
        .init(
            id: "edge-001", category: "edge", language: .enUS, style: .clean,
            input: "ok",
            goldenOutput: "Ok"),
        .init(
            id: "edge-002", category: "edge", language: .enUS, style: .clean,
            input: "",
            goldenOutput: ""),
        .init(
            id: "edge-003", category: "edge", language: .enUS, style: .professional,
            input: String(repeating: "very long input with numbers 1 2 3 ", count: 60),
            forbiddenTokens: []),
        .init(
            id: "edge-004", category: "edge", language: .enUS, style: .professional,
            input: "the answer is -5.5 and -5.5 again",
            forbiddenTokens: []),
    ]
}
