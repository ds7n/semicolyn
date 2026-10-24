// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// One rendered item in the keybar's scrollable region. `.fkey` is runtime-only
/// (Fn-engaged F-keys); `.slot` wraps a user-customizable layout slot (symbol, Fn,
/// or a slot moved down from the locked region, and custom/macro slots in 4d-2).
public enum KeybarScrollItem: Equatable, Sendable {
    case fkey(Int)
    case slot(KeybarSlot)
}

/// Resolve the scroll region's contents from the user's ordered scroll slots. F-key
/// mode is mutually exclusive with the slots and wins (function-keys spec); the Fn
/// slot stays last in both modes so it can be toggled back off.
public func keybarScrollItems(scrollSlots: [KeybarSlot],
                              fnEngaged: Bool) -> [KeybarScrollItem] {
    if fnEngaged {
        return (1...12).map { KeybarScrollItem.fkey($0) } + [.slot(.fn)]
    }
    return scrollSlots.map { KeybarScrollItem.slot($0) }
}
