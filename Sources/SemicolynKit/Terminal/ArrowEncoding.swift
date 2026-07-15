// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Encode one `ArrowRun` to its escape bytes, `count` times, honoring DECCKM
/// (application-cursor-keys): SS3 `ESC O A/B/C/D` when on, CSI `ESC [ A/B/C/D`
/// when off. Delegates to the shared `encodeKey(.arrow(…))` so tap-to-place and
/// alt-screen drag share one encoder (no more hardcoded-CSI copies in the App).
public func encodeArrowRun(_ run: ArrowRun, applicationCursorKeys: Bool) -> [UInt8] {
    guard run.count > 0 else { return [] }
    let one = encodeKey(.arrow(run.direction),
                        modifiers: KeyModifiers(),
                        applicationCursorKeys: applicationCursorKeys)
    var out: [UInt8] = []
    out.reserveCapacity(one.count * run.count)
    for _ in 0..<run.count { out.append(contentsOf: one) }
    return out
}

/// Encode one vertical `ArrowRun` as Page Up / Page Down escape bytes, `count` times.
/// `.up` -> PgUp (`ESC [ 5 ~`), `.down` -> PgDn (`ESC [ 6 ~`) — the same finger-direction
/// convention as `encodeArrowRun` (finger-down reveals content above = scroll back = PgUp).
/// Horizontal runs have no page-key analog (alt-screen scroll is vertical) -> empty.
/// Page keys are not affected by DECCKM, so there is no application-cursor variant.
public func encodePageKeyRun(_ run: ArrowRun) -> [UInt8] {
    guard run.count > 0 else { return [] }
    let one: [UInt8]
    switch run.direction {
    case .up:   one = [0x1b, 0x5b, 0x35, 0x7e]   // ESC [ 5 ~
    case .down: one = [0x1b, 0x5b, 0x36, 0x7e]   // ESC [ 6 ~
    case .left, .right: return []
    }
    var out: [UInt8] = []
    out.reserveCapacity(one.count * run.count)
    for _ in 0..<run.count { out.append(contentsOf: one) }
    return out
}
