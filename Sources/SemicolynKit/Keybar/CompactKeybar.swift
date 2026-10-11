// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// The built-in widgets the compact (hardware-keyboard) keybar may show.
private let compactKeybarBuiltins: Set<KeybarSlot> = [.escPill, .pad, .modifier, .tab]

/// The slots shown on the compact keybar when a hardware keyboard is connected:
/// the built-in widgets (Esc pill · Pad · Modifier · Tab) from each fixed region,
/// kept on their own side and in their existing order. Middle (scroll) slots and
/// non-built-ins are dropped (external-keyboard spec "Keybar behavior").
public func compactKeybarSlots(left: [KeybarSlot], right: [KeybarSlot]) -> (left: [KeybarSlot], right: [KeybarSlot]) {
    (left.filter { compactKeybarBuiltins.contains($0) },
     right.filter { compactKeybarBuiltins.contains($0) })
}
