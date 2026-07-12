// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// RenderSignature: equal iff two states render identically. Drives render-storm dedup.
final class RenderSignatureTests: XCTestCase {
    private func state(_ events: [ControlModeEvent]) -> TmuxSessionState {
        var s = TmuxSessionState()
        for e in events { s.apply(e) }
        return s
    }

    private func twoPaneLayout(_ ids: [UInt32]) -> PaneLayout {
        if ids.count == 1 {
            return .leaf(PaneID(raw: ids[0]), Geometry(w: 80, h: 24, x: 0, y: 0))
        }
        let width = UInt16(80 / ids.count)
        let children = ids.enumerated().map { i, id in
            PaneLayout.leaf(PaneID(raw: id), Geometry(w: width, h: 24, x: UInt16(i) * width, y: 0))
        }
        return .columns(children, Geometry(w: 80, h: 24, x: 0, y: 0))
    }

    // EP: the SAME state → equal signatures (→ caller skips the redundant render).
    func testSameStateEqualSignature() {
        let layout = twoPaneLayout([1, 2])
        let s = state([
            .sessionChanged(SessionID(raw: 0), name: "s"),
            .windowAdd(WindowID(raw: 1)),
            .sessionWindowChanged(SessionID(raw: 0), active: WindowID(raw: 1)),
            .layoutChange(WindowID(raw: 1), layout: layout, visible: layout, flags: ""),
        ])
        XCTAssertEqual(RenderSignature(s), RenderSignature(s))
    }

    // Active window changed → signatures differ (→ render, reason=active).
    func testActiveWindowChangeDiffers() {
        let base: [ControlModeEvent] = [
            .sessionChanged(SessionID(raw: 0), name: "s"),
            .windowAdd(WindowID(raw: 1)),
            .windowAdd(WindowID(raw: 2)),
        ]
        let a = state(base + [.sessionWindowChanged(SessionID(raw: 0), active: WindowID(raw: 1))])
        let b = state(base + [.sessionWindowChanged(SessionID(raw: 0), active: WindowID(raw: 2))])
        XCTAssertNotEqual(RenderSignature(a), RenderSignature(b))
    }

    // Window list changed (window added) → signatures differ.
    func testWindowListChangeDiffers() {
        let base: [ControlModeEvent] = [
            .sessionChanged(SessionID(raw: 0), name: "s"),
            .windowAdd(WindowID(raw: 1)),
            .sessionWindowChanged(SessionID(raw: 0), active: WindowID(raw: 1)),
        ]
        let a = state(base)
        let b = state(base + [.windowAdd(WindowID(raw: 2))])
        XCTAssertNotEqual(RenderSignature(a), RenderSignature(b))
    }

    // Active window's visible layout changed (pane set) → signatures differ.
    func testActiveLayoutChangeDiffers() {
        let base: [ControlModeEvent] = [
            .sessionChanged(SessionID(raw: 0), name: "s"),
            .windowAdd(WindowID(raw: 1)),
            .sessionWindowChanged(SessionID(raw: 0), active: WindowID(raw: 1)),
        ]
        let layoutA = twoPaneLayout([1, 2])
        let layoutB = twoPaneLayout([1, 2, 3])
        let a = state(base + [.layoutChange(WindowID(raw: 1), layout: layoutA, visible: layoutA, flags: "")])
        let b = state(base + [.layoutChange(WindowID(raw: 1), layout: layoutB, visible: layoutB, flags: "")])
        XCTAssertNotEqual(RenderSignature(a), RenderSignature(b))
    }

    // A change ONLY to a NON-active window's layout does NOT differ (we render the
    // active window; off-screen windows don't affect the rendered output).
    func testNonActiveLayoutChangeDoesNotDiffer() {
        let base: [ControlModeEvent] = [
            .sessionChanged(SessionID(raw: 0), name: "s"),
            .windowAdd(WindowID(raw: 1)),
            .windowAdd(WindowID(raw: 2)),
            .sessionWindowChanged(SessionID(raw: 0), active: WindowID(raw: 1)),
        ]
        let layoutA = twoPaneLayout([3])
        let layoutB = twoPaneLayout([3, 4])
        let a = state(base + [.layoutChange(WindowID(raw: 2), layout: layoutA, visible: layoutA, flags: "")])
        let b = state(base + [.layoutChange(WindowID(raw: 2), layout: layoutB, visible: layoutB, flags: "")])
        XCTAssertEqual(RenderSignature(a), RenderSignature(b))
    }
}
