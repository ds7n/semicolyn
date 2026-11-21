// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import UIKit
import SwiftTerm
import SemicolynKit

/// The ONLY place the App reads emulator state from SwiftTerm. Everything else asks
/// these members, so a SwiftTerm API change is contained to this file. SwiftTerm 2 has
/// no live `Terminal` on the view: every read here is a copied snapshot.
///
/// Row coordinates: `cursorCell.row` is relative to the live screen (the cursor lives
/// there); `viewportCellTexts` rows and `topVisibleRow` are relative to the viewport,
/// which differs from the live screen only while scrolled back.
///
/// Never call these from inside a SwiftTerm terminal callback (`bufferActivated`,
/// `mouseModeChanged`): the snapshots take the terminal lock that callback holds.
@MainActor
extension TerminalView {
    /// The grid size in cells.
    var gridSize: (cols: Int, rows: Int) {
        let d = terminalDimensions
        return (d.cols, d.rows)
    }

    /// The cursor cell, relative to the live screen.
    var cursorCell: (col: Int, row: Int) {
        let pos = terminalStateSnapshot().cursor
        return (pos.col, pos.row)
    }

    /// The scrollback row at the top of the viewport (`yDisp`).
    var topVisibleRow: Int { terminalStateSnapshot().viewportRow }

    /// The emulator's input modes, read now. All off when no terminal is attached.
    var inputModes: TerminalInputModes {
        guard let s = terminalInputStateSnapshot() else { return .unavailable }
        return TerminalInputModes(isAlternateBuffer: s.isAlternateBuffer,
                                  applicationCursor: s.applicationCursor,
                                  mouseReporting: s.mouseMode != .off)
    }

    /// Every viewport row as one String per column (an unwritten or wide-continuation
    /// cell is "" or NUL), top first. One copy of the viewport.
    func viewportCellTexts() -> [[String]] {
        let cols = gridSize.cols
        // `.viewport`, never `.rows(...)`: `.rows` takes absolute rows, which drift from
        // viewport rows once scrollback is trimmed.
        guard let snap = terminalContentSnapshot(region: .viewport) else { return [] }
        return snap.rows.map { row in
            let texts = row.cells.map(\.text)
            return texts.count >= cols ? texts : texts + Array(repeating: "", count: cols - texts.count)
        }
    }

    /// One viewport row as one String per column, or nil when `row` is outside the
    /// viewport. Copies the whole viewport; batch with `viewportCellTexts()` instead
    /// when reading many rows.
    func viewportCellTexts(row: Int) -> [String]? {
        let rows = viewportCellTexts()
        guard row >= 0, row < rows.count else { return nil }
        return rows[row]
    }

    /// Resize the scrollback (only this resizes an existing buffer).
    func setScrollback(_ lines: Int) {
        changeScrollback(lines)
    }

    /// The scroll-state fragment of the `geo:*` diagnostic lines.
    var geometryDebugFields: String {
        "topRow\(topVisibleRow) yDisp\(topVisibleRow)"
    }
}

extension Terminal {
    /// The input modes, for SwiftTerm's own callbacks (`bufferActivated`,
    /// `mouseModeChanged`), which hand over the `Terminal` itself with its lock held.
    var inputModes: TerminalInputModes {
        TerminalInputModes(isAlternateBuffer: isCurrentBufferAlternate,
                           applicationCursor: applicationCursor,
                           mouseReporting: mouseMode != .off)
    }
}

/// Terminal options for a new view. The kitty image cache cap (security audit L5) is
/// set here because SwiftTerm 2 fixes it at creation; it now counts per screen, so each
/// screen gets half of the old combined budget.
func paneTerminalOptions() -> TerminalOptions {
    var options = TerminalOptions.default
    options.kittyGraphics.storageLimitBytesPerScreen =
        UInt32(clamping: SemicolynKit.kittyImageCacheLimitBytes / 2)
    return options
}
