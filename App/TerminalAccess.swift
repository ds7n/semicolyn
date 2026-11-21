// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import UIKit
import SwiftTerm
import SemicolynKit

/// The ONLY place the App reads emulator state from SwiftTerm. Everything else asks
/// these members, so a SwiftTerm API change (1.x `getTerminal()` versus 2.x copied
/// snapshots) is contained to this file.
///
/// Row coordinates: `cursorCell.row` is relative to the live screen (the cursor lives
/// there); `viewportCellTexts` rows and `topVisibleRow` are relative to the viewport,
/// which differs from the live screen only while scrolled back.
@MainActor
extension TerminalView {
    /// The grid size in cells.
    var gridSize: (cols: Int, rows: Int) {
        let t = getTerminal()
        return (t.cols, t.rows)
    }

    /// The cursor cell, relative to the live screen.
    var cursorCell: (col: Int, row: Int) {
        let pos = getTerminal().getCursorLocation()   // (x, y) column/row
        return (pos.x, pos.y)
    }

    /// The scrollback row at the top of the viewport (`yDisp`).
    var topVisibleRow: Int { getTerminal().getTopVisibleRow() }

    /// The emulator's input modes, read now.
    var inputModes: TerminalInputModes { getTerminal().inputModes }

    /// Every viewport row as one String per column (an unwritten cell is ""), top first.
    func viewportCellTexts() -> [[String]] {
        let rows = gridSize.rows
        return (0..<max(rows, 0)).compactMap { viewportCellTexts(row: $0) }
    }

    /// One viewport row as one String per column (an unwritten cell is ""), or nil when
    /// `row` is outside the viewport.
    func viewportCellTexts(row: Int) -> [String]? {
        let t = getTerminal()
        guard row >= 0, row < t.rows else { return nil }
        // getCharData(col:row:) is viewport-relative (it adds yDisp itself).
        return (0..<t.cols).map { col in
            t.getCharData(col: col, row: row).map { String($0.getCharacter()) } ?? ""
        }
    }

    /// Resize the scrollback. `changeScrollback`, not `options.scrollback =`: the buffer
    /// already exists, and only this resizes it.
    func setScrollback(_ lines: Int) {
        getTerminal().changeScrollback(lines)
    }

    /// Cap the kitty image cache (security audit L5).
    func applyKittyCacheLimit(_ bytes: Int) {
        getTerminal().options.kittyImageCacheLimitBytes = bytes
    }

    /// The scroll-state fragment of the `geo:*` diagnostic lines.
    var geometryDebugFields: String {
        let t = getTerminal(), b = t.buffer
        return "topRow\(t.getTopVisibleRow()) yDisp\(b.yDisp) scroll\(b.scrollTop)..\(b.scrollBottom)"
    }
}

extension Terminal {
    /// The input modes, for SwiftTerm's own callbacks (`bufferActivated`,
    /// `mouseModeChanged`), which hand over the `Terminal` itself.
    var inputModes: TerminalInputModes {
        TerminalInputModes(isAlternateBuffer: isCurrentBufferAlternate,
                           applicationCursor: applicationCursor,
                           mouseReporting: mouseMode != .off)
    }
}
