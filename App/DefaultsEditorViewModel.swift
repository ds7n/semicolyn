// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import SemicolynKit

/// View-model for the Connection Defaults editor. Owns the `Defaults` record and
/// writes every change straight back to the store (live apply, like every other
/// Settings screen: there is no Save or Cancel).
@MainActor final class DefaultsEditorViewModel: ObservableObject {
    @Published var defaults: Defaults {
        didSet {
            guard defaults != oldValue else { return }
            persist()
        }
    }

    /// The last store failure, shown as an alert; nil when the last write succeeded.
    @Published var saveError: String?

    /// The saved SSH keys, for the "Default SSH key" picker.
    let identities: [Identity]

    init() {
        defaults = (try? AppStores.shared.hosts.defaults()) ?? Defaults()
        identities = (try? AppStores.shared.hosts.allIdentities()) ?? []
    }

    /// The values unset fields fall back to on this screen (the built-ins).
    var fallbacks: InheritedFallbacks { .builtIn }

    private func persist() {
        do {
            try AppStores.shared.hosts.saveDefaults(defaults)
            saveError = nil
        } catch {
            DebugLog.shared.log(.lifecycle, "defaults:save FAILED \(error.localizedDescription)")
            saveError = error.localizedDescription
        }
    }
}
