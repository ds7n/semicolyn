// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// The outcome of evaluating an offered host key against stored trusted keys for
/// a given `(host, algorithm)` pair.
public enum HostKeyDecision: Equatable, Sendable {
    /// The offered fingerprint matches a stored entry of this algorithm — all good.
    case trusted
    /// No stored entry exists for this algorithm — first-trust opportunity.
    case firstTrust
    /// Entries of this algorithm exist but none match the offered fingerprint — potential MITM.
    case mismatch(stored: [HostKey])
}

/// Trust-decision core for Glymr's TOFU (trust-on-first-use) host-key model.
///
/// Each `(host, algorithm)` pair is evaluated independently: a new algorithm on a
/// known host is `.firstTrust`, not `.mismatch`. Mutation methods (`trust`, `replace`)
/// are the only way to change storage; `evaluate` is always pure and non-mutating.
public struct HostKeyTrustEvaluator {
    private let store: HostKeyStore

    public init(store: HostKeyStore) {
        self.store = store
    }

    /// Evaluate the offered key against stored entries for `(hostID, algorithm)`.
    ///
    /// - Returns: `.trusted` if the fingerprint is already stored, `.firstTrust` if no
    ///   entry exists for this algorithm, or `.mismatch(stored:)` listing the conflicting
    ///   stored entries.
    public func evaluate(hostID: UUID, algorithm: String, fingerprint: String) throws -> HostKeyDecision {
        let matching = try store.entries(forHost: hostID).filter { $0.algorithm == algorithm }
        if matching.isEmpty { return .firstTrust }
        if matching.contains(where: { $0.fingerprint == fingerprint }) { return .trusted }
        return .mismatch(stored: matching)
    }

    /// Append a `.trustOnFirstUse` entry for `(hostID, algorithm, fingerprint)`.
    ///
    /// Intended for first-trust acceptance; does not remove any existing entries.
    public func trust(hostID: UUID, algorithm: String, fingerprint: String, at now: Date) throws {
        let key = HostKey(algorithm: algorithm, fingerprint: fingerprint, addedAt: now, source: .trustOnFirstUse)
        try store.add(key, forHost: hostID)
    }

    /// Replace all stored entries of `algorithm` for `hostID` with a new `.trustOnFirstUse` entry.
    ///
    /// Entries of other algorithms are left untouched. Use after confirming a legitimate
    /// host-key rotation (the user has accepted the mismatch).
    public func replace(hostID: UUID, algorithm: String, fingerprint: String, at now: Date) throws {
        let toRemove = try store.entries(forHost: hostID).filter { $0.algorithm == algorithm }
        // `toRemove` is pre-filtered to this algorithm, so each fingerprint passed
        // to the store's remove(fingerprint:) belongs to this algorithm only.
        for entry in toRemove {
            try store.remove(fingerprint: entry.fingerprint, forHost: hostID)
        }
        let key = HostKey(algorithm: algorithm, fingerprint: fingerprint, addedAt: now, source: .trustOnFirstUse)
        try store.add(key, forHost: hostID)
    }
}
