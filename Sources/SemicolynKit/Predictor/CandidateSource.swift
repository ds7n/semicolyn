// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// A token paired with its estimated frequency, the scored candidate the
/// ranker works over.
public struct TokenCount: Equatable, Sendable {
    public let token: String
    public let count: UInt32
    public init(token: String, count: UInt32) {
        self.token = token
        self.count = count
    }
}

/// Anything that can answer "which scored tokens have this prefix?", the one
/// operation suggestion ranking needs. Lets the ranker read one sketch or a
/// windowed aggregate without knowing which. See
/// `2026-06-21-predictor-candidate-aggregate-design`.
public protocol CandidateSource {
    func candidates(forPrefix prefix: String) -> [TokenCount]
}

/// Sums several candidate sources: unions their prefix matches and adds each
/// token's count across sources (saturating). This realizes the predictor's
/// `today ⊕ rolling_<window>` query on the read side — estimating each token in
/// each source and adding, rather than materializing a merged sketch per
/// keystroke. Both are pointwise sums; this preserves the one-sided error (each
/// estimate `≥` its true count, so the sum `≥` the true combined count).
public struct AggregateCandidateSource: CandidateSource {
    private let sources: [any CandidateSource]

    public init(_ sources: [any CandidateSource]) {
        self.sources = sources
    }

    public func candidates(forPrefix prefix: String) -> [TokenCount] {
        var totals: [String: UInt32] = [:]
        for source in sources {
            for candidate in source.candidates(forPrefix: prefix) {
                let (sum, overflow) = totals[candidate.token, default: 0]
                    .addingReportingOverflow(candidate.count)
                totals[candidate.token] = overflow ? .max : sum
            }
        }
        return totals
            .map { TokenCount(token: $0.key, count: $0.value) }
            .sorted { $0.token.utf8.lexicographicallyPrecedes($1.token.utf8) }
    }
}
