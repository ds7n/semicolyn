// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import NeotildeKit

/// App-lifetime holder for the user's selected theme id. Persists the raw id
/// string in `UserDefaults` (mirrors `KeybarSettingsStore`); the root view
/// resolves it through `resolveTheme(...)` against Pro state and injects the
/// result into the environment. A missing key falls back to the free default.
@MainActor final class ThemeSettingsStore: ObservableObject {
    private static let defaultsKey = "neotilde.appearance.themeID"

    /// Persisted id deliberately un-validated; `resolveDescriptor` is the single guard (unknown/Pro-lapsed id resolves to default at render time).
    @Published var selectedThemeID: ThemeID {
        didSet { persist() }
    }

    init() {
        if let raw = UserDefaults.standard.string(forKey: Self.defaultsKey) {
            self.selectedThemeID = ThemeID(raw)
        } else {
            self.selectedThemeID = Theme.defaultDescriptor.id
        }
    }

    /// Restores the free default (Neon Midnight). Intentional forward seam for a future Settings "Reset" affordance (mirrors `KeybarSettingsStore.resetToDefaults`).
    func resetToDefault() {
        selectedThemeID = Theme.defaultDescriptor.id
    }

    private func persist() {
        UserDefaults.standard.set(selectedThemeID.raw, forKey: Self.defaultsKey)
    }
}
