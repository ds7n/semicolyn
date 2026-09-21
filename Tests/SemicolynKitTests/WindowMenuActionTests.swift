// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// Each window-menu action maps to tmux's default single-key prefix binding.
/// These are load-bearing: a wrong key silently does the wrong tmux action.
final class WindowMenuActionTests: XCTestCase {
    func testEachActionMapsToItsPrefixKey() {
        XCTAssertEqual(WindowMenuAction.splitHorizontal.prefixKey, "%")
        XCTAssertEqual(WindowMenuAction.splitVertical.prefixKey, "\"")
        XCTAssertEqual(WindowMenuAction.closePane.prefixKey, "x")
        XCTAssertEqual(WindowMenuAction.newWindow.prefixKey, "c")
        XCTAssertEqual(WindowMenuAction.zoom.prefixKey, "z")
    }

    // Guard against a new case being added without a key (CaseIterable keeps this honest).
    func testAllActionsHaveAKey() {
        for a in WindowMenuAction.allCases {
            XCTAssertNotNil(a.prefixKey.asciiValue, "\(a) key must be ASCII")
        }
    }
}
