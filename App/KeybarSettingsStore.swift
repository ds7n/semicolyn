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

    // MARK: - Library (4d-2 macros + custom slots)

    /// Mints a fresh, unique macro id. The pure tier stays id-agnostic; the App
    /// supplies UUID strings.
    func mintMacroID() -> MacroID { MacroID(UUID().uuidString) }
    func mintCustomSlotID() -> CustomSlotID { CustomSlotID(UUID().uuidString) }

    /// Inserts or updates a macro in the library (edits propagate to every slot
    /// that references it, since slots resolve by id at render time).
    func saveMacro(_ macro: Macro) { settings.library.upsertMacro(macro) }

    /// Inserts or updates a custom slot in the library.
    func saveCustomSlot(_ slot: CustomSlot) { settings.library.upsertCustomSlot(slot) }

    /// Deletes a macro and prunes any pinned-macro slot that referenced it (an
    /// orphaned custom-slot binding simply resolves to "unbound" at render).
    func deleteMacro(_ id: MacroID) {
        settings.library.removeMacro(id)
        settings.layout = KeybarLayout(
            locked: settings.layout.locked.filter { $0 != .pinnedMacro(id) },
            scroll: settings.layout.scroll.filter { $0 != .pinnedMacro(id) })
    }

    /// Deletes a custom slot and removes it from the bar.
    func deleteCustomSlot(_ id: CustomSlotID) {
        settings.library.removeCustomSlot(id)
        settings.layout = KeybarLayout(
            locked: settings.layout.locked.filter { $0 != .custom(id) },
            scroll: settings.layout.scroll.filter { $0 != .custom(id) })
    }

    /// Appends a slot to the (default) scroll region, if not already on the bar.
    func appendToScroll(_ slot: KeybarSlot) {
        let present = Set(settings.layout.locked + settings.layout.scroll)
        guard !present.contains(slot) else { return }
        settings.layout = KeybarLayout(locked: settings.layout.locked,
                                       scroll: settings.layout.scroll + [slot])
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}
