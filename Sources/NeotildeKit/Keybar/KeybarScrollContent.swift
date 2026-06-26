// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// One rendered item in the keybar's scrollable region. `.promotion` and
/// `.fkey` are runtime-only (context promotions / Fn-engaged F-keys); `.slot`
/// wraps a user-customizable layout slot (symbol, Fn, or a slot moved down from
/// the locked region — and custom/macro slots in 4d-2).
public enum KeybarScrollItem: Equatable, Sendable {
    case promotion(PromotionSlot)
    case fkey(Int)
    case slot(KeybarSlot)
}

/// Resolve the scroll region's contents from runtime promotions and the user's
/// ordered scroll slots. F-key mode is mutually exclusive with promotions+slots
/// and wins (function-keys spec §"Interaction with symbol promotions"); the Fn
/// slot stays last in both modes so it can be toggled back off.
public func keybarScrollItems(promotions: [PromotionSlot],
                              scrollSlots: [KeybarSlot],
                              fnEngaged: Bool) -> [KeybarScrollItem] {
    if fnEngaged {
        return (1...12).map { KeybarScrollItem.fkey($0) } + [.slot(.fn)]
    }
    return promotions.map { KeybarScrollItem.promotion($0) }
        + scrollSlots.map { KeybarScrollItem.slot($0) }
}
