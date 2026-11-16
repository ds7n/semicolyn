// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import SemicolynKit

/// App-lifetime holder for the user's selected theme id. Persists the raw id
/// string in `UserDefaults` (mirrors `KeybarSettingsStore`); the root view
/// resolves it through `resolveTheme(...)` against Pro state and injects the
/// result into the environment. A missing key falls back to the free default.
@MainActor final class ThemeSettingsStore: ObservableObject {
    private static let defaultsKey = "semicolyn.appearance.themeID"
    private static let modeKey = "semicolyn.appearance.mode"

    /// Persisted id deliberately un-validated; `resolveDescriptor` is the single guard (unknown/Pro-lapsed id resolves to default at render time).
    @Published var selectedThemeID: ThemeID {
        didSet { persist() }
    }

    /// A theme shown live while the picker previews it (a Supporter theme without
    /// Pro). Never persisted; the picker clears it when it goes away, so the app
    /// reverts to `selectedThemeID`. See `displayedDescriptor`.
    @Published var previewThemeID: ThemeID?

    /// System (follow the phone), Light or Dark. A missing or unknown stored value
    /// reads as the default (System).
    @Published var appearanceMode: AppearanceMode {
        didSet { UserDefaults.standard.set(appearanceMode.rawValue, forKey: Self.modeKey) }
    }

    init() {
        if let raw = UserDefaults.standard.string(forKey: Self.defaultsKey) {
            self.selectedThemeID = ThemeID(raw)
        } else {
            self.selectedThemeID = Theme.defaultDescriptor.id
        }
        self.appearanceMode = UserDefaults.standard.string(forKey: Self.modeKey)
            .flatMap(AppearanceMode.init(rawValue:)) ?? .defaultMode
    }

    /// Restores the free default (Neon Midnight) and System appearance. Intentional forward seam for a future Settings "Reset" affordance (mirrors `KeybarSettingsStore.resetKeepingLibrary`).
    func resetToDefault() {
        selectedThemeID = Theme.defaultDescriptor.id
        appearanceMode = .defaultMode
    }

    private func persist() {
        UserDefaults.standard.set(selectedThemeID.raw, forKey: Self.defaultsKey)
    }
}
