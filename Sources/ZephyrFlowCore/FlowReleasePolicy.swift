import Foundation

// JOE-2281: preregistered Flow release budgets + exact-candidate regression
// gate. Policy/corpus review and immutable exact-candidate provenance must be
// enforced outside this evaluator. A Swift let in the candidate's own source
// does not establish preregistration or prevent a later source edit.

/// Per-style release budget (preregistered, immutable).
public struct FlowStyleBudget: Sendable, Equatable {
    public let style: FlowStyle
    /// Critical protected-span violations allowed (0 for conservative/
    /// structural paths: sign/unit/identifier/negation must be exact).
    public let maxCriticalViolations: Int
    /// Maximum fallback rate (0.0–1.0 fraction of cases using fallback).
    public let maxFallbackRate: Double
    /// Minimum deterministic stability (fraction of cases with identical
    /// output across repeated runs).
    public let minDeterministicStability: Double
    /// Maximum acceptable no-op rate (fraction producing unchanged output).
    public let maxNoopRate: Double

    public init(
        style: FlowStyle, maxCriticalViolations: Int,
        maxFallbackRate: Double, minDeterministicStability: Double,
        maxNoopRate: Double
    ) {
        self.style = style
        self.maxCriticalViolations = maxCriticalViolations
        self.maxFallbackRate = maxFallbackRate
        self.minDeterministicStability = minDeterministicStability
        self.maxNoopRate = maxNoopRate
    }
}

/// Machine-readable release policy (CI/exact-candidate pass/fail driver).
public struct FlowReleasePolicy: Sendable, Equatable {
    public let version: Int
    public let baselineCommit: String
    public let corpusVersion: Int
    public let budgets: [FlowStyle: FlowStyleBudget]

    public init(
        version: Int, baselineCommit: String, corpusVersion: Int,
        budgets: [FlowStyle: FlowStyleBudget]
    ) {
        self.version = version
        self.baselineCommit = baselineCommit
        self.corpusVersion = corpusVersion
        self.budgets = budgets
    }

    /// The current candidate's policy — preregistered; changing thresholds
    /// requires a new baseline version with reviewed rationale.
    public static let current = FlowReleasePolicy(
        version: 1,
        baselineCommit: "agent/zephyr-production-run-20260808T103416Z@3059542",
        corpusVersion: FlowFidelityCorpus.version,
        budgets: [
            .clean: FlowStyleBudget(
                style: .clean, maxCriticalViolations: 0,
                maxFallbackRate: 0.05, minDeterministicStability: 1.0,
                maxNoopRate: 0.5),
            .professional: FlowStyleBudget(
                style: .professional, maxCriticalViolations: 0,
                maxFallbackRate: 0.10, minDeterministicStability: 1.0,
                maxNoopRate: 0.5),
            .bullets: FlowStyleBudget(
                style: .bullets, maxCriticalViolations: 0,
                maxFallbackRate: 0.10, minDeterministicStability: 1.0,
                maxNoopRate: 0.3),
            .summary: FlowStyleBudget(
                style: .summary, maxCriticalViolations: 0,
                maxFallbackRate: 0.15, minDeterministicStability: 1.0,
                maxNoopRate: 0.4),
            .raw: FlowStyleBudget(
                style: .raw, maxCriticalViolations: 0,
                maxFallbackRate: 0.0, minDeterministicStability: 1.0,
                maxNoopRate: 1.0),
        ])
}

/// Per-style statistics computed by the harness over the corpus.
public struct FlowStyleStats: Sendable, Equatable {
    public let style: FlowStyle
    public let totalCases: Int
    public let criticalViolations: Int  // sign/unit/identifier/negation/protected
    public let fallbackCount: Int
    public let noopCount: Int
    public let deterministicCount: Int

    public init(
        style: FlowStyle, totalCases: Int, criticalViolations: Int,
        fallbackCount: Int, noopCount: Int, deterministicCount: Int
    ) {
        self.style = style
        self.totalCases = totalCases
        self.criticalViolations = criticalViolations
        self.fallbackCount = fallbackCount
        self.noopCount = noopCount
        self.deterministicCount = deterministicCount
    }

    public var fallbackRate: Double { totalCases == 0 ? 0 : Double(fallbackCount) / Double(totalCases) }
    public var noopRate: Double { totalCases == 0 ? 0 : Double(noopCount) / Double(totalCases) }
    public var deterministicStability: Double { totalCases <= 0 ? 0 : Double(deterministicCount) / Double(totalCases) }
}

/// Gate verdict (machine-readable).
public enum FlowReleaseGateResult: Sendable, Equatable {
    case pass
    case fail(reason: String)
}

/// Exact-candidate regression gate.
public enum FlowReleaseGate {
    /// - Parameters:
    ///   - corpusVersion: the corpus version the candidate ran against.
    ///   - stats: per-style corpus statistics.
    ///   - policy: the reviewed policy. Callers must verify its provenance.
    public static func evaluate(
        corpusVersion: Int,
        stats: [FlowStyle: FlowStyleStats],
        policy: FlowReleasePolicy
    ) -> FlowReleaseGateResult {
        // Corpus mismatch => the candidate ran against the wrong corpus.
        guard corpusVersion == policy.corpusVersion else {
            return .fail(reason: "corpus version mismatch: candidate=\(corpusVersion) policy=\(policy.corpusVersion)")
        }
        guard !policy.budgets.isEmpty, policy.version > 0, !policy.baselineCommit.isEmpty else {
            return .fail(reason: "missing or invalid release policy")
        }
        guard Set(stats.keys).isSubset(of: Set(policy.budgets.keys)) else {
            return .fail(reason: "statistics include a style with no reviewed budget")
        }
        // Stable diagnostics order, independent of Dictionary enumeration.
        for style in policy.budgets.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let budget = policy.budgets[style], budget.style == style, budget.maxCriticalViolations >= 0,
                [budget.maxFallbackRate, budget.minDeterministicStability, budget.maxNoopRate]
                    .allSatisfy({ $0.isFinite && (0...1).contains($0) })
            else {
                return .fail(reason: "\(style.rawValue): invalid release budget")
            }
            guard let s = stats[style] else { return .fail(reason: "\(style.rawValue): missing statistics") }
            guard s.style == style, s.totalCases > 0, s.criticalViolations >= 0,
                [s.fallbackCount, s.noopCount, s.deterministicCount].allSatisfy({ (0...s.totalCases).contains($0) })
            else {
                return .fail(reason: "\(style.rawValue): empty or invalid statistics")
            }
            if s.criticalViolations > budget.maxCriticalViolations {
                return .fail(
                    reason:
                        "\(style.rawValue): critical violations \(s.criticalViolations) > budget \(budget.maxCriticalViolations)"
                )
            }
            if s.fallbackRate > budget.maxFallbackRate {
                return .fail(
                    reason: "\(style.rawValue): fallback rate \(s.fallbackRate) > budget \(budget.maxFallbackRate)")
            }
            if s.deterministicStability < budget.minDeterministicStability {
                return .fail(
                    reason:
                        "\(style.rawValue): stability \(s.deterministicStability) < \(budget.minDeterministicStability)"
                )
            }
            if s.noopRate > budget.maxNoopRate {
                return .fail(reason: "\(style.rawValue): noop rate \(s.noopRate) > \(budget.maxNoopRate)")
            }
        }
        return .pass
    }
}
