// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class PaneLayoutPanesTests: XCTestCase {
    func testSingleLeafFlattens() {
        let layout: PaneLayout = .leaf(PaneID(raw: 1), Geometry(w: 80, h: 24, x: 0, y: 0))
        let flat = layout.panes
        XCTAssertEqual(flat.count, 1)
        XCTAssertEqual(flat[0].pane, PaneID(raw: 1))
        XCTAssertEqual(flat[0].geometry, Geometry(w: 80, h: 24, x: 0, y: 0))
    }
    func testColumnsFlattenInOrder() {
        let layout: PaneLayout = .columns([
            .leaf(PaneID(raw: 1), Geometry(w: 40, h: 24, x: 0, y: 0)),
            .leaf(PaneID(raw: 2), Geometry(w: 39, h: 24, x: 41, y: 0)),
        ], Geometry(w: 80, h: 24, x: 0, y: 0))
        XCTAssertEqual(layout.panes.map(\.pane), [PaneID(raw: 1), PaneID(raw: 2)])
    }
    func testNestedFlattensDepthFirst() {
        let layout: PaneLayout = .columns([
            .leaf(PaneID(raw: 1), Geometry(w: 40, h: 24, x: 0, y: 0)),
            .rows([
                .leaf(PaneID(raw: 2), Geometry(w: 39, h: 12, x: 41, y: 0)),
                .leaf(PaneID(raw: 3), Geometry(w: 39, h: 11, x: 41, y: 13)),
            ], Geometry(w: 39, h: 24, x: 41, y: 0)),
        ], Geometry(w: 80, h: 24, x: 0, y: 0))
        XCTAssertEqual(layout.panes.map(\.pane),
                       [PaneID(raw: 1), PaneID(raw: 2), PaneID(raw: 3)])
    }
}
