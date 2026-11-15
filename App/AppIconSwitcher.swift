// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import UIKit
import SemicolynKit

/// Thin wrapper over `UIApplication`'s alternate-icon API. Which icon is allowed is
/// decided in SemicolynKit (`resolveIcon`); this only reads and sets it.
@MainActor enum AppIconSwitcher {
    /// The icon in use now, as iOS reports it.
    static var current: AppIconVariant {
        resolveIcon(currentAlternateName: UIApplication.shared.alternateIconName, unlocked: true)
    }

    /// Switches to `icon` (iOS shows its own confirmation alert). No-op if already current.
    static func select(_ icon: AppIconVariant) async {
        let app = UIApplication.shared
        guard app.supportsAlternateIcons, app.alternateIconName != icon.alternateIconName else { return }
        do {
            try await app.setAlternateIconName(icon.alternateIconName)
            DebugLog.shared.log(.lifecycle, "app-icon: set \(icon.id)")
        } catch {
            DebugLog.shared.log(.lifecycle, "app-icon: set \(icon.id) failed (\(error))")
        }
    }

    /// Puts back the primary icon when the current one is a locked Supporter icon (or
    /// one the catalog no longer has). Called at launch, on Erase All Data and when the
    /// Supporter preview turns off.
    static func enforce(unlocked: Bool) {
        let app = UIApplication.shared
        guard app.supportsAlternateIcons else { return }
        let allowed = resolveIcon(currentAlternateName: app.alternateIconName, unlocked: unlocked)
        guard allowed.alternateIconName != app.alternateIconName else { return }
        Task { await select(allowed) }
    }
}
