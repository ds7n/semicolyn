// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// True iff the input chunk contains a line-editing key (DEL `0x7f` or BS `0x08`).
/// The predictor refresh is otherwise gated on printable scalars; a backspace produces
/// no printable scalar, so without this the strip keeps stale chips after a correction
/// (spec addendum 2026-08-21, Fix 2). Pure; Linux-tested.
public func containsEditingKey(_ bytes: [UInt8]) -> Bool {
    bytes.contains { $0 == 0x7f || $0 == 0x08 }
}
