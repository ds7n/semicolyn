// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// One keybar slot. v1 (4a) ships the four built-in widgets plus default symbol
/// slots; custom slots / macros / Fn arrive in later 4x slices.
public enum KeybarSlot: Equatable, Sendable {
    case escPill
    case pad
    case modifier
    case tab
    case symbol(String)
}

/// The keybar's slot composition, split into the locked region (never scrolls)
/// and the horizontally scrollable region. 4a renders `.default`; the
/// Settings→Keybar editor that mutates this is Phase 4d.
public struct KeybarLayout: Equatable, Sendable {
    public let locked: [KeybarSlot]
    public let scroll: [KeybarSlot]
    public init(locked: [KeybarSlot], scroll: [KeybarSlot]) {
        self.locked = locked; self.scroll = scroll
    }

    /// Locked `Esc · Pad · Modifier · Tab`; scroll = the six convenience symbols
    /// (keybar-customization spec "Default locked-left composition" + "Scroll region").
    public static let `default` = KeybarLayout(
        locked: [.escPill, .pad, .modifier, .tab],
        scroll: [.symbol("/"), .symbol("|"), .symbol("~"), .symbol("-"), .symbol("("), .symbol(")")]
    )
}
