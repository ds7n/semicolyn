// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import NeotildeKit

/// App-lifetime holder for the user's keybar customization (slot layout +
/// reverse-bar direction). Persists as JSON in `UserDefaults`; the
/// Settings→Keybar editor mutates `settings` and the live `KeybarView` reacts.
///
/// Mirrors `TerminalSettingsStore` but adds persistence — keybar layout must
/// survive relaunch, whereas terminal prefs are still ephemeral.
@MainActor final class KeybarSettingsStore: ObservableObject {
    private static let defaultsKey = "neotilde.keybarSettings"

    @Published var settings: KeybarSettings {
        didSet { persist() }
    }

    /// Loads the persisted layout, falling back to `KeybarSettings.default` when
    /// nothing is stored or the stored payload fails to decode (forward-compat
    /// safety — a malformed/old blob never bricks the keybar).
    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode(KeybarSettings.self, from: data) {
            self.settings = decoded
        } else {
            self.settings = .default
        }
    }

    /// Resets the layout to the v1 defaults (Settings→Keybar "Reset to defaults").
    func resetToDefaults() {
        settings = .default
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}
