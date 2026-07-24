// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class PaneRectsTests: XCTestCase {
    private let cw = 8.0, ch = 16.0

    func testSinglePaneFillsWindow() {
        let layout = PaneLayout.leaf(PaneID(raw: 0), Geometry(w: 80, h: 24, x: 0, y: 0))
        XCTAssertEqual(paneRects(in: layout, cellWidth: cw, cellHeight: ch),
                       [PaneRect(pane: PaneID(raw: 0), x: 0, y: 0, width: 640, height: 384)])
    }

    func testSideBySideSplitColumns() {
        // 80x24 window split into two 40-wide columns (divider ignored; panes abut).
        let left  = PaneLayout.leaf(PaneID(raw: 1), Geometry(w: 40, h: 24, x: 0,  y: 0))
        let right = PaneLayout.leaf(PaneID(raw: 2), Geometry(w: 40, h: 24, x: 41, y: 0))
        let layout = PaneLayout.columns([left, right], Geometry(w: 80, h: 24, x: 0, y: 0))
        XCTAssertEqual(paneRects(in: layout, cellWidth: cw, cellHeight: ch), [
            PaneRect(pane: PaneID(raw: 1), x: 0,   y: 0, width: 320, height: 384),
            PaneRect(pane: PaneID(raw: 2), x: 328, y: 0, width: 320, height: 384),
        ])
    }

    func testStackedSplitRows() {
        let top    = PaneLayout.leaf(PaneID(raw: 1), Geometry(w: 80, h: 12, x: 0, y: 0))
        let bottom = PaneLayout.leaf(PaneID(raw: 2), Geometry(w: 80, h: 11, x: 0, y: 13))
        let layout = PaneLayout.rows([top, bottom], Geometry(w: 80, h: 24, x: 0, y: 0))
        XCTAssertEqual(paneRects(in: layout, cellWidth: cw, cellHeight: ch), [
            PaneRect(pane: PaneID(raw: 1), x: 0, y: 0,   width: 640, height: 192),
            PaneRect(pane: PaneID(raw: 2), x: 0, y: 208, width: 640, height: 176),
        ])
    }

    func testNestedGridPreservesOrderAndGeometry() {
        // Left column is itself a 2-row stack → 3 leaves total.
        let lt = PaneLayout.leaf(PaneID(raw: 1), Geometry(w: 40, h: 12, x: 0, y: 0))
        let lb = PaneLayout.leaf(PaneID(raw: 2), Geometry(w: 40, h: 11, x: 0, y: 13))
        let leftCol = PaneLayout.rows([lt, lb], Geometry(w: 40, h: 24, x: 0, y: 0))
        let right = PaneLayout.leaf(PaneID(raw: 3), Geometry(w: 39, h: 24, x: 41, y: 0))
        let layout = PaneLayout.columns([leftCol, right], Geometry(w: 80, h: 24, x: 0, y: 0))
        let rects = paneRects(in: layout, cellWidth: cw, cellHeight: ch)
        XCTAssertEqual(rects.map(\.pane), [PaneID(raw: 1), PaneID(raw: 2), PaneID(raw: 3)])
        XCTAssertEqual(rects[0], PaneRect(pane: PaneID(raw: 1), x: 0, y: 0,   width: 320, height: 192))
        XCTAssertEqual(rects[1], PaneRect(pane: PaneID(raw: 2), x: 0, y: 208, width: 320, height: 176))
        XCTAssertEqual(rects[2], PaneRect(pane: PaneID(raw: 3), x: 328, y: 0, width: 312, height: 384))
    }

    // MARK: fitPaneRects — stretch tmux's lagging layout to the real usable area.

    // The device bug: a single pane framed from a lagging tmux layout (280pt tall) into a
    // taller usable area (356pt) leaves a gap. Fitting stretches it to fill exactly.
    func testFitSinglePaneStretchesToUsableArea() {
        let raw = [PaneRect(pane: PaneID(raw: 0), x: 0, y: 0, width: 400, height: 280)]
        let fitted = fitPaneRects(raw, toWidth: 400, toHeight: 356)
        XCTAssertEqual(fitted, [PaneRect(pane: PaneID(raw: 0), x: 0, y: 0, width: 400, height: 356)])
    }

    // Exact-fit input is unchanged (no spurious scaling when tmux already matches).
    func testFitSinglePaneAlreadyExactIsIdentity() {
        let raw = [PaneRect(pane: PaneID(raw: 0), x: 0, y: 0, width: 400, height: 356)]
        XCTAssertEqual(fitPaneRects(raw, toWidth: 400, toHeight: 356), raw)
    }

    // A vertical split scales BOTH panes by the same factors and keeps them abutting
    // (no gap, no overlap): bounding box 640×360 → fill 400×720 (sx=0.625, sy=2.0).
    func testFitStackedSplitScalesProportionally() {
        let raw = [
            PaneRect(pane: PaneID(raw: 1), x: 0, y: 0,   width: 640, height: 180),
            PaneRect(pane: PaneID(raw: 2), x: 0, y: 180, width: 640, height: 180),
        ]
        let fitted = fitPaneRects(raw, toWidth: 400, toHeight: 720)
        XCTAssertEqual(fitted, [
            PaneRect(pane: PaneID(raw: 1), x: 0, y: 0,   width: 400, height: 360),
            PaneRect(pane: PaneID(raw: 2), x: 0, y: 360, width: 400, height: 360),
        ])
        // Panes still tile the target with no gap: pane2.y == pane1.height, sum == target.
        XCTAssertEqual(fitted[0].height + fitted[1].height, 720, accuracy: 1e-9)
        XCTAssertEqual(fitted[1].y, fitted[0].height, accuracy: 1e-9)
    }

    // Non-zero origin (a right/bottom pane) is honored: the bounding box is offset-based,
    // so the fitted pane starts at 0 and fills the target.
    func testFitHonorsNonZeroOrigin() {
        let raw = [PaneRect(pane: PaneID(raw: 3), x: 328, y: 0, width: 312, height: 280)]
        XCTAssertEqual(fitPaneRects(raw, toWidth: 312, toHeight: 356),
                       [PaneRect(pane: PaneID(raw: 3), x: 0, y: 0, width: 312, height: 356)])
    }

    // Fail-closed: a non-positive target returns the rects UNCHANGED (never emits a
    // zero/negative frame that would collapse the pane).
    func testFitDegenerateTargetReturnsUnchanged() {
        let raw = [PaneRect(pane: PaneID(raw: 0), x: 0, y: 0, width: 400, height: 280)]
        XCTAssertEqual(fitPaneRects(raw, toWidth: 400, toHeight: 0), raw)
        XCTAssertEqual(fitPaneRects(raw, toWidth: -1, toHeight: 356), raw)
    }

    // Fail-closed: empty input → empty (no crash on the min/max reductions).
    func testFitEmptyIsEmpty() {
        XCTAssertEqual(fitPaneRects([], toWidth: 400, toHeight: 356), [])
    }
}
