// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import NeotildeKit

/// View-model for the Defaults editor. Owns the in-flight `Defaults` draft and
/// exposes a single `save()` method that writes it back to the store.
///
/// All sections collapsed by default (no required fields — Save is always enabled).
@MainActor final class DefaultsEditorViewModel: ObservableObject {
    @Published var defaults: Defaults

    init() {
        defaults = (try? AppStores.shared.hosts.defaults()) ?? Defaults()
    }

    /// Persists the current draft to `HostStore`.
    func save() throws {
        try AppStores.shared.hosts.saveDefaults(defaults)
    }
}
