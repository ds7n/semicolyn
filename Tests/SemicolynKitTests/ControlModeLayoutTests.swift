// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class ControlModeLayoutTests: XCTestCase {
    private func feed(_ s: String) -> [ControlModeEvent] {
        ControlModeParser().feed(Array(s.utf8))
    }

    func testLayoutChangeParsesBothLayouts() {
        let s = "%layout-change @1 bc62,80x24,0,0,1 bc62,80x24,0,0,1 *\n"
        let leaf: PaneLayout = .leaf(PaneID(raw: 1), Geometry(w: 80, h: 24, x: 0, y: 0))
        let expected: ControlModeEvent = .layoutChange(WindowID(raw: 1), layout: leaf, visible: leaf, flags: "*")
        XCTAssertEqual(feed(s), [expected])
    }
    func testLayoutChangeWithZoomedVisibleLayout() {
        // visible layout differs (a single zoomed pane)
        let s = "%layout-change @2 e5e4,80x24,0,0{40x24,0,0,1,39x24,41,0,2} bc62,80x24,0,0,1 Z\n"
        let split: PaneLayout = .columns([
            .leaf(PaneID(raw: 1), Geometry(w: 40, h: 24, x: 0, y: 0)),
            .leaf(PaneID(raw: 2), Geometry(w: 39, h: 24, x: 41, y: 0)),
        ], Geometry(w: 80, h: 24, x: 0, y: 0))
        let zoomed: PaneLayout = .leaf(PaneID(raw: 1), Geometry(w: 80, h: 24, x: 0, y: 0))
        let expected: ControlModeEvent = .layoutChange(WindowID(raw: 2), layout: split, visible: zoomed, flags: "Z")
        XCTAssertEqual(feed(s), [expected])
    }
    func testBadWindowIsMalformed() {
        if case .malformed = feed("%layout-change %1 bc62,80x24,0,0,1 bc62,80x24,0,0,1 *\n").first {} else {
            XCTFail("expected .malformed for non-window id")
        }
    }
    func testBadLayoutStringIsMalformed() {
        if case .malformed = feed("%layout-change @1 bc62,80x24,0,0{1 bc62,80x24,0,0,1 *\n").first {} else {
            XCTFail("expected .malformed for unparseable layout")
        }
    }
    func testMissingFieldIsMalformed() {
        if case .malformed = feed("%layout-change @1 bc62,80x24,0,0,1\n").first {} else {
            XCTFail("expected .malformed for missing visible-layout/flags")
        }
    }
}
