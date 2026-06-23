// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import GlymrKit

/// Drives `HostListView`: owns the loaded host list and surfaces delete
/// failures as a user-facing error string.
@MainActor
final class HostListViewModel: ObservableObject {
    @Published var hosts: [Host] = []
    /// Non-nil when `deleteHost` is refused because another host uses the
    /// target as a jump host. Cleared by the view after the alert is dismissed.
    @Published var deleteError: String?

    /// Reloads `hosts` from `HostStore`. Silences errors — a missing or
    /// unreadable store is treated as an empty library rather than a crash.
    func reload() {
        hosts = (try? AppStores.shared.hosts.allHosts()) ?? []
    }

    /// Attempts to delete `host`. On success, removes it from the in-memory
    /// list immediately (no second reload needed). On
    /// `StoreError.jumpHostInUse` sets `deleteError` to the verbatim
    /// refusal message from the spec; any other error is also surfaced.
    func delete(_ host: Host) {
        do {
            try AppStores.shared.hosts.deleteHost(id: host.id)
            hosts.removeAll { $0.id == host.id }
        } catch StoreError.jumpHostInUse(let referrers) {
            let labels = referrers.map(\.label).joined(separator: ", ")
            deleteError = "Cannot delete '\(host.label)'. Used as jumphost by: \(labels). Remove these references first."
        } catch {
            deleteError = error.localizedDescription
        }
    }
}
