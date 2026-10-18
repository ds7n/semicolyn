// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Deterministic hold-out rule for the tldr evaluation set: about one page in ten is
/// held out by a stable hash of its stem, so the evaluation text is reproducible.
public enum TldrHoldout {
    private static let basis: UInt64 = 0xcbf29ce484222325
    private static let prime: UInt64 = 0x100000001b3

    /// True when the page named `pageStem` (file name without extension) is held out.
    /// FNV-1a 64 over the UTF-8 bytes; held out when `hash % 10 == 0`.
    public static func isHeldOut(pageStem: String) -> Bool {
        var hash = basis
        for byte in pageStem.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return hash % 10 == 0
    }
}
