// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// The authoritative store of user-created macros and custom slots. The keybar
/// layout references these by id (`.pinnedMacro` / `.custom` slots); editing a
/// macro here updates everywhere it's used. Persisted as part of `KeybarSettings`
/// (keybar-customization spec "Macro library").
public struct KeybarLibrary: Equatable, Sendable, Codable {
    public var macros: [Macro]
    public var customSlots: [CustomSlot]

    public init(macros: [Macro] = [], customSlots: [CustomSlot] = []) {
        self.macros = macros
        self.customSlots = customSlots
    }

    /// An empty library (the v1 default — no user macros or custom slots yet).
    public static let empty = KeybarLibrary()

    // MARK: - Lookups

    public func macro(_ id: MacroID) -> Macro? { macros.first { $0.id == id } }
    public func customSlot(_ id: CustomSlotID) -> CustomSlot? { customSlots.first { $0.id == id } }

    // MARK: - Mutations (upsert keeps a single entry per id)

    /// Inserts `macro`, or replaces the existing entry with the same id in place.
    public mutating func upsertMacro(_ macro: Macro) {
        if let i = macros.firstIndex(where: { $0.id == macro.id }) {
            macros[i] = macro
        } else {
            macros.append(macro)
        }
    }

    /// Inserts `slot`, or replaces the existing entry with the same id in place.
    public mutating func upsertCustomSlot(_ slot: CustomSlot) {
        if let i = customSlots.firstIndex(where: { $0.id == slot.id }) {
            customSlots[i] = slot
        } else {
            customSlots.append(slot)
        }
    }

    public mutating func removeMacro(_ id: MacroID) {
        macros.removeAll { $0.id == id }
    }

    public mutating func removeCustomSlot(_ id: CustomSlotID) {
        customSlots.removeAll { $0.id == id }
    }
}
