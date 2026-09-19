// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// Tap on a tmux pane: mouse-on forwards a click (tmux selects the exact pane);
/// mouse-off cycles with the prefix key. The single source of truth for the branch.
final class TapPaneRouteTests: XCTestCase {
    func testMouseOnForwardsClick() {
        XCTAssertEqual(tapPaneRoute(mouseModeOn: true), .forwardClick)
    }

    func testMouseOffCyclesPrefix() {
        XCTAssertEqual(tapPaneRoute(mouseModeOn: false), .cyclePrefix)
    }
}
