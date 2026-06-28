// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// A lightweight reference to a host for user-facing messages (label) that still
/// carries the stable UUID. Used in refusal errors and usage scans.
public struct HostRef: Equatable, Sendable {
    public let id: UUID
    public let label: String
    public init(id: UUID, label: String) {
        self.id = id
        self.label = label
    }
}

/// Errors raised by the host repository's save/delete invariants.
public enum StoreError: Error, Equatable {
    /// Saving the host would create a loop in its `proxyJump` chain.
    case jumpChainCycle
    /// The host can't be deleted because other hosts use it as a jump host.
    case jumpHostInUse(by: [HostRef])
    /// The identity can't be deleted because hosts still reference it.
    case identityInUse(by: [HostRef])
}

/// The result of a successful save. Duplicate labels are a soft-uniqueness
/// **warning** (the save still happened) — never a failure.
public struct SaveOutcome: Equatable, Sendable {
    public let duplicateLabels: [HostRef]
    public init(duplicateLabels: [HostRef]) {
        self.duplicateLabels = duplicateLabels
    }
}

/// Repository over `EncryptedRecordStore` for hosts, the Defaults singleton, and
/// identity metadata, enforcing the host-config-model / identities-keys
/// invariants: cycle prevention at save, soft-unique label warning, and
/// refuse-delete of a referenced jump host or identity.
public struct HostStore {
    private let records: EncryptedRecordStore

    /// Fixed sentinel id for the singleton Defaults record.
    private static let defaultsID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    public init(records: EncryptedRecordStore) {
        self.records = records
    }

    // MARK: Hosts

    /// Persist `host`. Throws `.jumpChainCycle` if its jump chain loops. Returns
    /// the duplicate-label warning (other hosts sharing this label); duplicates
    /// never block the save.
    @discardableResult
    public func saveHost(_ host: SemicolynKit.Host) throws -> SaveOutcome {
        let others = try allHosts().filter { $0.id != host.id }
        var byID = Dictionary(uniqueKeysWithValues: others.map { ($0.id, $0) })
        byID[host.id] = host   // detect cycles against the NEW chain
        if hasCycle(savingHostId: host.id, chain: host.resolvedJumpChain, in: byID) {
            throw StoreError.jumpChainCycle
        }
        let dups = others.filter { $0.label == host.label }.map { HostRef(id: $0.id, label: $0.label) }
        try records.put(host, type: .host, id: host.id)
        return SaveOutcome(duplicateLabels: dups)
    }

    public func host(id: UUID) throws -> SemicolynKit.Host? {
        try records.get(.host, id: id, as: SemicolynKit.Host.self)
    }

    public func allHosts() throws -> [SemicolynKit.Host] {
        try records.list(.host, as: SemicolynKit.Host.self).map(\.value)
    }

    /// Delete the host. Throws `.jumpHostInUse` if any other host references it as
    /// a jump host (no silent cascade — the user reroutes the dependents first).
    public func deleteHost(id: UUID) throws {
        let referrers = try allHosts()
            .filter { $0.id != id && $0.resolvedJumpChain.contains { isRef($0, to: id) } }
            .map { HostRef(id: $0.id, label: $0.label) }
        guard referrers.isEmpty else { throw StoreError.jumpHostInUse(by: referrers) }
        try records.delete(.host, id: id)
    }

    // MARK: Defaults singleton

    /// The Defaults record, or an empty `Defaults()` when none has been saved.
    public func defaults() throws -> Defaults {
        try records.get(.defaults, id: Self.defaultsID, as: Defaults.self) ?? Defaults()
    }

    public func saveDefaults(_ d: Defaults) throws {
        try records.put(d, type: .defaults, id: Self.defaultsID)
    }

    // MARK: Identities

    public func saveIdentity(_ identity: Identity) throws {
        try records.put(identity, type: .identity, id: identity.id)
    }

    public func identity(id: UUID) throws -> Identity? {
        try records.get(.identity, id: id, as: Identity.self)
    }

    public func allIdentities() throws -> [Identity] {
        try records.list(.identity, as: Identity.self).map(\.value)
    }

    /// Hosts that reference `identityID`, via their `identities` list or any
    /// inline jump hop's identities. Computed on demand (no persisted index).
    public func hostsUsing(identityID: UUID) throws -> [HostRef] {
        try allHosts()
            .filter { host in
                (host.identities.value?.contains(identityID) ?? false)
                    || host.resolvedJumpChain.contains { inlineUses($0, identityID) }
            }
            .map { HostRef(id: $0.id, label: $0.label) }
    }

    /// Delete the identity. Throws `.identityInUse` if any host still references it.
    public func deleteIdentity(id: UUID) throws {
        let users = try hostsUsing(identityID: id)
        guard users.isEmpty else { throw StoreError.identityInUse(by: users) }
        try records.delete(.identity, id: id)
    }

    // MARK: Helpers

    private func isRef(_ hop: JumpHop, to id: UUID) -> Bool {
        if case let .ref(hostId) = hop { return hostId == id }
        return false
    }

    private func inlineUses(_ hop: JumpHop, _ identityID: UUID) -> Bool {
        if case let .inline(_, _, _, identities) = hop {
            return identities?.contains(identityID) ?? false
        }
        return false
    }
}
