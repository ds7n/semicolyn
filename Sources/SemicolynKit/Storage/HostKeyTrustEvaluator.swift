// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// The outcome of evaluating an offered host key against stored trusted keys for
/// a given `(host, algorithm)` pair.
public enum HostKeyDecision: Equatable, Sendable {
    /// The offered fingerprint matches a stored entry of this algorithm, all good.
    case trusted
    /// Nothing is stored for this host at all: first-trust opportunity.
    case firstTrust
    /// The host is known, but only by keys of OTHER algorithms (listed, in stored order).
    /// A server normally keeps offering the same key type, so this is a possible MITM
    /// downgrade or substitution: the prompt must warn, not read as a first connection.
    case newKeyType(known: [HostKey])
    /// Entries of this algorithm exist but none match the offered fingerprint, potential MITM.
    case mismatch(stored: [HostKey])
}

/// Trust-decision core for Semicolyn's TOFU (trust-on-first-use) host-key model.
///
/// Each `(host, algorithm)` pair is evaluated independently: a new algorithm on a
/// known host is `.newKeyType` (a warning), not `.mismatch`; `.firstTrust` is only for a
/// host with nothing stored. Mutation methods (`trust`, `replace`)
/// are the only way to change storage; `evaluate` is always pure and non-mutating.
public struct HostKeyTrustEvaluator {
    private let store: HostKeyStore

    public init(store: HostKeyStore) {
        self.store = store
    }

    /// Evaluate the offered key against stored entries for `(hostID, algorithm)`.
    ///
    /// - Returns: `.trusted` if the fingerprint is already stored (under any algorithm
    ///   name: the SHA256 fingerprint covers the key type, so an equal fingerprint is the
    ///   same key), `.mismatch(stored:)` listing this algorithm's conflicting entries,
    ///   `.newKeyType(known:)` when only other algorithms are stored, or `.firstTrust`
    ///   when nothing is stored for the host.
    public func evaluate(hostID: UUID, algorithm: String, fingerprint: String) throws -> HostKeyDecision {
        let all = try store.entries(forHost: hostID)
        if all.contains(where: { $0.fingerprint == fingerprint }) { return .trusted }
        let matching = all.filter { $0.algorithm == algorithm }
        if !matching.isEmpty { return .mismatch(stored: matching) }
        return all.isEmpty ? .firstTrust : .newKeyType(known: all)
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
