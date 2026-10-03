// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// A left-button single click in SGR 1006 mouse form: a press (button 0, final
/// byte 'M') then a release (final byte 'm') at the SAME 1-based cell. tmux with
/// `mouse on` selects the pane the click lands in. Coordinates are 1-based and
/// already clamped to the grid by the caller (this is a pure formatter). Mirrors
/// the existing wheel encoder byte format (`ArrowEncoding.encodeWheelRun`).
public func sgrMouseClick(col: Int, row: Int) -> [UInt8] {
    let press = "\u{1b}[<0;\(col);\(row)M"
    let release = "\u{1b}[<0;\(col);\(row)m"
    return Array((press + release).utf8)
}
