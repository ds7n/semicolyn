// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// Under tmux, an active pane in an app-owned mode must still deliver the tap
/// (with coords) so it can be forwarded to tmux (click / cycle) - NOT yield.
/// Without tmux, app-owned panes keep yielding (unchanged).
final class PaneTapActionTmuxTests: XCTestCase {
    func testTmuxAppOwnedActivePaneDeliversTapNotYield() {
        let a = paneTapAction(isActivePane: true, mode: .appOwnsInput,
                              hasSelection: false, tapInsideSelection: false, isTmux: true)
        XCTAssertEqual(a, .active(.placeCursor))
    }

    func testNonTmuxAppOwnedActivePaneStillYields() {
        let a = paneTapAction(isActivePane: true, mode: .appOwnsInput,
                              hasSelection: false, tapInsideSelection: false, isTmux: false)
        XCTAssertEqual(a, .yield)
    }

    func testTmuxLocalScrollUnchanged() {
        let a = paneTapAction(isActivePane: true, mode: .localScroll,
                              hasSelection: false, tapInsideSelection: false, isTmux: true)
        XCTAssertEqual(a, .active(.placeCursor))
    }
}
