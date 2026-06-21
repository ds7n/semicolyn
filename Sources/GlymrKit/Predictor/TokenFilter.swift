// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// A rule for excluding a token from the learned vocabulary.
public enum ExcludePattern: Sendable, Equatable {
    /// Case-insensitive substring (e.g. `password` in `MyPassword`).
    case contains(String)
    /// Case-sensitive prefix (e.g. a fixed-case key prefix `ghp_`).
    case hasPrefix(String)
}

/// Write-time privacy filter: decides whether a token must never be recorded by
/// the predictor, so secrets never enter any sketch. A pure predicate the
/// recording orchestration consults *before* `record` — filtering at write time,
/// not read time. Fails toward exclusion (learning a secret is the costly
/// failure). See `2026-06-21-predictor-privacy-filter-design`.
public struct TokenFilter: Sendable {
    public var patterns: [ExcludePattern]
    /// Bits-per-character Shannon-entropy ceiling; `nil` disables the backstop.
    public var entropyThreshold: Double?
    /// Tokens shorter than this are never entropy-excluded (short strings have
    /// low entropy regardless).
    public var entropyMinLength: Int

    /// The exclude rules shipped with the app.
    public static let defaultPatterns: [ExcludePattern] = [
        .contains("password"), .contains("token"), .contains("secret"),
        .hasPrefix("ghp_"), .hasPrefix("gho_"), .hasPrefix("ghs_"),  // GitHub classic PATs
        .hasPrefix("github_pat_"),                                   // GitHub fine-grained PATs
        .hasPrefix("sk-"),                                           // OpenAI API keys
        .hasPrefix("sk_"), .hasPrefix("pk_"),                        // Stripe secret / publishable keys
    ]

    public init(patterns: [ExcludePattern] = TokenFilter.defaultPatterns,
                entropyThreshold: Double? = 4.0,
                entropyMinLength: Int = 16) {
        self.patterns = patterns
        self.entropyThreshold = entropyThreshold
        self.entropyMinLength = entropyMinLength
    }

    /// True if `token` must never be recorded. Checks the deterministic patterns
    /// (high confidence) then the entropy backstop.
    public func excludes(_ token: String) -> Bool {
        let lowered = token.lowercased()
        for pattern in patterns {
            switch pattern {
            case .contains(let needle):
                // An empty needle is a no-op, never a match-everything rule.
                if !needle.isEmpty, lowered.contains(needle.lowercased()) { return true }
            case .hasPrefix(let prefix):
                if !prefix.isEmpty, token.hasPrefix(prefix) { return true }
            }
        }
        if let threshold = entropyThreshold,
           token.unicodeScalars.count >= entropyMinLength,
           shannonEntropy(token) >= threshold {
            return true
        }
        return false
    }
}

/// Shannon entropy of `s` in bits per character, over Unicode-scalar
/// frequencies: `H = -Σ pᵢ·log2(pᵢ)`. Length-independent (a measure of
/// per-character unpredictability); `0` for empty or fully-repeated input.
func shannonEntropy(_ s: String) -> Double {
    let scalars = Array(s.unicodeScalars)
    guard !scalars.isEmpty else { return 0 }
    var frequency: [UnicodeScalar: Int] = [:]
    for scalar in scalars { frequency[scalar, default: 0] += 1 }
    let total = Double(scalars.count)
    var entropy = 0.0
    for count in frequency.values {
        let p = Double(count) / total
        entropy -= p * log2(p)
    }
    return entropy
}
