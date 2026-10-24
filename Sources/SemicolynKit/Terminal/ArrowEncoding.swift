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

/// Encode one vertical `ArrowRun` as SGR mouse-wheel event bytes, `count` times:
/// `ESC [ < Cb ; col ; row M`, where Cb = 64 (`.up`) / 65 (`.down`). Press-only (SGR wheel
/// sends no release). `col`/`row` are 1-based cell coordinates (the drag point). Horizontal
/// directions have no wheel analog -> empty. This is the Blink-validated alt-screen scroll
/// mechanism: many terminal apps (Claude/vim/less) scroll ~one line per wheel event.
public func encodeWheelRun(_ run: ArrowRun, col: Int, row: Int) -> [UInt8] {
    guard run.count > 0 else { return [] }
    let button: Int
    switch run.direction {
    case .up:   button = 64
    case .down: button = 65
    case .left, .right: return []
    }
    let one = Array("\u{1b}[<\(button);\(col);\(row)M".utf8)
    var out: [UInt8] = []
    out.reserveCapacity(one.count * run.count)
    for _ in 0..<run.count { out.append(contentsOf: one) }
    return out
}
