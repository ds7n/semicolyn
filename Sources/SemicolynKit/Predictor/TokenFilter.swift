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
        // L5 (Phase 3) — curated public credential-format prefixes.
        .hasPrefix("AKIA"), .hasPrefix("ASIA"),                      // AWS access key IDs
        .hasPrefix("AIza"),                                          // Google API keys
        .hasPrefix("sk_live_"), .hasPrefix("rk_live_"),             // Stripe live keys (narrower than sk_)
        .hasPrefix("xoxb-"), .hasPrefix("xoxa-"),                    // Slack bot / app tokens
        .hasPrefix("xoxp-"), .hasPrefix("xoxr-"), .hasPrefix("xoxs-"), // Slack user/refresh/config tokens
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
        if isStructuredSecret(token) { return true }
        if let threshold = entropyThreshold,
           token.unicodeScalars.count >= entropyMinLength,
           shannonEntropy(token) >= threshold {
            return true
        }
        return false
    }

    /// Entropy band below the hard exclusion threshold: tokens in this band are
    /// near-random enough that L7 should graduate them low-confidence (count only,
    /// no persisted literal). Auditable named constant for the security tier.
    private static let softMargin = 0.75

    /// Soft L5 signal: true when `token` is NOT a hard-excluded secret but sits in an
    /// entropy band just below the hard threshold — near-random enough that L7 should
    /// graduate it low-confidence (count only, no persisted literal). Returns false
    /// when the entropy backstop is disabled or the token is too short/low-entropy.
    public func isPatternAdjacent(_ token: String) -> Bool {
        guard let threshold = entropyThreshold,
              token.unicodeScalars.count >= entropyMinLength else { return false }
        let h = shannonEntropy(token)
        return h >= threshold - Self.softMargin && h < threshold
    }
}

/// True if `token` is a structurally-shaped secret that no fixed prefix catches:
/// a JWT (three `.`-separated base64url segments, first beginning `eyJ`) or a PEM
/// PRIVATE KEY header. Conservative: only PRIVATE (not PUBLIC/CERTIFICATE) PEM
/// headers, and JWT requires the standard `eyJ` (`{"` base64url) leader so a plain
/// dotted hostname/version does not match.
func isStructuredSecret(_ token: String) -> Bool {
    // JWT: eyJ… . … . …  (exactly three non-empty base64url segments).
    if token.hasPrefix("eyJ") {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        if segments.count == 3, segments.allSatisfy({ !$0.isEmpty && isBase64URL($0) }) {
            return true
        }
    }
    // PEM private key header (any key type: RSA / OPENSSH / EC / plain).
    if token.hasPrefix("-----BEGIN") && token.contains("PRIVATE KEY") {
        return true
    }
    return false
}

/// True if `s` contains only base64url characters (A–Z a–z 0–9 - _ =).
private func isBase64URL(_ s: Substring) -> Bool {
    s.allSatisfy { c in
        c.isLetter || c.isNumber || c == "-" || c == "_" || c == "="
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
