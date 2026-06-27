// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// The built-in widgets the compact (hardware-keyboard) keybar may show, in no
/// particular order — actual order comes from the user's locked region.
private let compactKeybarBuiltins: Set<KeybarSlot> = [.escPill, .pad, .modifier, .tab]

/// The slots shown on the compact keybar when a hardware keyboard is connected:
/// the built-in widgets (Esc pill · Pad · Modifier · Tab) drawn from the user's
/// locked region in their existing order, skipping any the user removed and any
/// non-built-in slot that strayed into locked. A strict subset of the locked-left
/// default (external-keyboard spec "Keybar behavior").
public func compactKeybarSlots(locked: [KeybarSlot]) -> [KeybarSlot] {
    locked.filter { compactKeybarBuiltins.contains($0) }
}
