// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// One rendered item in the keybar's scrollable region.
public enum KeybarScrollItem: Equatable, Sendable {
    case promotion(PromotionSlot)
    case symbol(String)
    case fn
    case fkey(Int)
}

/// Resolve the scroll region's contents. F-key mode is mutually exclusive with
/// promotions+defaults and wins (function-keys spec §"Interaction with symbol
/// promotions"); the Fn slot stays last in both modes so it can be toggled.
public func keybarScrollItems(promotions: [PromotionSlot],
                              defaultSymbols: [String],
                              fnEngaged: Bool) -> [KeybarScrollItem] {
    if fnEngaged {
        return (1...12).map { KeybarScrollItem.fkey($0) } + [.fn]
    }
    return promotions.map { KeybarScrollItem.promotion($0) }
        + defaultSymbols.map { KeybarScrollItem.symbol($0) }
        + [.fn]
}
