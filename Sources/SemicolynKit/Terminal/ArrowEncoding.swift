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
