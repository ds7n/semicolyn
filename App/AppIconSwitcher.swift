// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import UIKit
import SemicolynKit

/// Thin wrapper over `UIApplication`'s alternate-icon API. Which icon is allowed is
/// decided in SemicolynKit (`resolveIcon`); this reads and sets it and publishes the
/// icon in use, so the picker's checkmark follows changes made elsewhere (the preview
/// turning off, Erase All Data) once iOS has actually applied them.
@MainActor final class AppIconSwitcher: ObservableObject {
    static let shared = AppIconSwitcher()

    /// The id of the icon in use, refreshed after every change.
    @Published private(set) var currentID: String

    private init() {
        currentID = Self.readCurrent().id
    }

    /// Switches to `icon` (iOS shows its own confirmation alert). No-op if already current.
    func select(_ icon: AppIconVariant) async {
        let app = UIApplication.shared
        guard app.supportsAlternateIcons, app.alternateIconName != icon.alternateIconName else { return }
        do {
            try await app.setAlternateIconName(icon.alternateIconName)
            DebugLog.shared.log(.lifecycle, "app-icon: set \(icon.id)")
        } catch {
            DebugLog.shared.log(.lifecycle, "app-icon: set \(icon.id) failed (\(error))")
        }
        currentID = Self.readCurrent().id
    }

    /// Puts back the primary icon when the current one is a locked Supporter icon (or
    /// one the catalog no longer has). Called at launch, on Erase All Data and when the
    /// Supporter preview turns off.
    func enforce(unlocked: Bool) async {
        let app = UIApplication.shared
        guard app.supportsAlternateIcons else { return }
        let allowed = resolveIcon(currentAlternateName: app.alternateIconName, unlocked: unlocked)
        if allowed.alternateIconName != app.alternateIconName {
            await select(allowed)
        }
        currentID = Self.readCurrent().id
    }

    private static func readCurrent() -> AppIconVariant {
        resolveIcon(currentAlternateName: UIApplication.shared.alternateIconName, unlocked: true)
    }
}
