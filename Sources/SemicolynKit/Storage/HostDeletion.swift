// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Deletes host `id` and the Keychain secrets only it owns: its trusted host keys
/// (`SecretRef.hostKeys`) and its saved password (`SecretRef.password(id:)`, keyed on
/// the host's own id by the host editor). The host record goes first, so a refused
/// delete (`StoreError.jumpHostInUse`) leaves every secret in place.
///
/// - Throws: whatever `HostStore.deleteHost(id:)` throws (nothing is removed), or a
///   `SecretStore` error after the record is gone (the host is deleted; a secret may
///   be left behind, as before this cleanup existed).
public func deleteHostAndSecrets(id: UUID, hosts: HostStore, secrets: SecretStore) throws {
    try hosts.deleteHost(id: id)
    try HostKeyStore(secrets: secrets).removeAll(forHost: id)
    try secrets.deleteSecret(.password(id: id))
}
