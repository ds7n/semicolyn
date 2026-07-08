// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import SemicolynKit

/// App-lifetime holder for terminal preferences. Persists the whole
/// `TerminalSettings` as a JSON blob in `UserDefaults` (mirrors
/// `ThemeSettingsStore`); a missing/corrupt key falls back to defaults.
@MainActor final class TerminalSettingsStore: ObservableObject {
    private static let defaultsKey = "semicolyn.terminal.settings"

    @Published var settings: TerminalSettings {
        didSet { persist() }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode(TerminalSettings.self, from: data) {
            self.settings = decoded
        } else {
            self.settings = TerminalSettings()
        }
    }

    func resetToDefaults() {
        settings = TerminalSettings()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}
