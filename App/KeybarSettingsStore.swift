// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import SemicolynKit

/// App-lifetime holder for the user's keybar customization (three-region slot
/// layout + library). Sealed in the encrypted record store, since macros can hold
/// commands the user types (privacy audit P-L1); the first load moves a layout still
/// in `UserDefaults` across. The Settings→Keybar editor mutates `settings` and the
/// live `KeybarView` reacts.
@MainActor final class KeybarSettingsStore: ObservableObject {
    /// Where the settings lived before P-L1; read once to move them.
    private static let legacyDefaultsKey = "semicolyn.keybarSettings"

    private let records: EncryptedRecordStore
    /// False while the stored settings couldn't be read (the device was locked at
    /// launch): edits stay in memory and nothing is saved, so the defaults shown
    /// meanwhile can't overwrite the user's real layout and macros.
    private var canSave = true

    @Published var settings: KeybarSettings {
        didSet { persist() }
    }

    /// Loads the persisted layout, falling back to `KeybarSettings.default` when
    /// nothing is stored or the stored payload fails to decode (forward-compat
    /// safety, a malformed/old blob never bricks the keybar).
    init(records: EncryptedRecordStore) {
        self.records = records
        let (loaded, readable) = Self.load(records)
        self.canSave = readable
        self.settings = loaded
    }

    /// Re-reads the store (after Erase All Data deleted it: back to the defaults).
    func reload() {
        let (loaded, readable) = Self.load(records)
        canSave = readable
        settings = loaded
    }

    /// Retries a load that failed because the device was locked. Called when the app
    /// becomes active (the device is unlocked then).
    func reloadIfUnreadable() {
        guard !canSave else { return }
        reload()
    }

    private static func load(_ records: EncryptedRecordStore) -> (KeybarSettings, readable: Bool) {
        let defaults = UserDefaults.standard
        let result = loadSealedSetting(
            id: SealedSettingID.keybar, as: KeybarSettings.self, records: records,
            legacy: {
                defaults.data(forKey: legacyDefaultsKey)
                    .flatMap { try? JSONDecoder().decode(KeybarSettings.self, from: $0) }
            },
            removeLegacy: { defaults.removeObject(forKey: legacyDefaultsKey) })
        switch result {
        case let .found(stored): return (stored, true)
        case .absent: return (.default, true)
        case .unreadable:
            DebugLog.shared.log(.keybar, "keybar:settings unreadable (device locked?), not saving until reloaded")
            return (.default, false)
        }
    }

    /// Settings > Keybar > "Reset Keybar…": layout, swipes and the hardware-keyboard
    /// toggle return to the defaults; macros and gesture keys are kept
    /// (`KeybarSettings.resettingKeepingLibrary`).
    func resetKeepingLibrary() {
        settings = settings.resettingKeepingLibrary()
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
        settings.layout = settings.layout.filtering { $0 != .pinnedMacro(id) }
    }

    /// Deletes a custom slot and removes it from the bar.
    func deleteCustomSlot(_ id: CustomSlotID) {
        settings.library.removeCustomSlot(id)
        settings.layout = settings.layout.filtering { $0 != .custom(id) }
    }

    /// Appends a slot to the scrolling middle region, if not already on the bar.
    func appendToMiddle(_ slot: KeybarSlot) {
        settings.layout = settings.layout.appending(slot, to: .middle)
    }

    private func persist() {
        guard canSave else { return }
        do {
            try records.put(settings, type: .settings, id: SealedSettingID.keybar)
            DebugLog.shared.log(.keybar, "keybar:settingsApplied")
        } catch {
            DebugLog.shared.log(.keybar, "keybar:settings save failed error=\(error)")
        }
    }
}
