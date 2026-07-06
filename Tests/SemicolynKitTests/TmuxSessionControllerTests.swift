// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// `TmuxSessionController` orchestration. Per
/// `2026-06-20-tmux-session-controller-design`: pure state machine, no I/O —
/// `start` yields the exec string, `feed` folds bytes into state + resolves
/// commands, `submit` frames a command for correlation.
final class TmuxSessionControllerTests: XCTestCase {
    /// Feed a control-mode line (as raw bytes) the way the channel would.
    private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    // MARK: start / handshake

    func testStartReturnsExecCreateOrAttachString() {
        let c = TmuxSessionController()
        XCTAssertEqual(c.start(sessionName: "semicolyn-a3f7c2e9"),
                       "tmux -CC new-session -A -s semicolyn-a3f7c2e9")
        XCTAssertEqual(c.lifecycle, .attaching)
    }

    func testStartRejectsInvalidSessionName() {
        let c = TmuxSessionController()
        XCTAssertNil(c.start(sessionName: "bad name; rm -rf"))
        XCTAssertEqual(c.lifecycle, .idle, "rejected start must not advance lifecycle")
    }

    func testStartIsOnceOnly() {
        let c = TmuxSessionController()
        _ = c.start(sessionName: "semicolyn-a3f7c2e9")
        XCTAssertNil(c.start(sessionName: "semicolyn-a3f7c2e9"), "second start must be refused")
    }

    func testSessionChangedTransitionsToAttached() {
        let c = TmuxSessionController()
        _ = c.start(sessionName: "semicolyn-a3f7c2e9")
        let out = c.feed(bytes("%session-changed $7 semicolyn-a3f7c2e9\n"))
        XCTAssertEqual(c.lifecycle, .attached)
        XCTAssertTrue(out.lifecycleChanged)
        XCTAssertTrue(out.stateChanged)
        XCTAssertEqual(c.state.sessionID, SessionID(raw: 7))
        XCTAssertEqual(c.state.sessionName, "semicolyn-a3f7c2e9")
    }

    func testExitTransitionsToExitedWithReason() {
        let c = TmuxSessionController()
        _ = c.start(sessionName: "semicolyn-a3f7c2e9")
        _ = c.feed(bytes("%session-changed $7 semicolyn-a3f7c2e9\n"))
        let out = c.feed(bytes("%exit server exited\n"))
        XCTAssertEqual(c.lifecycle, .exited(reason: "server exited"))
        XCTAssertTrue(out.lifecycleChanged)
        XCTAssertTrue(c.state.ended)
    }

    func testExitWithoutReason() {
        let c = TmuxSessionController()
        _ = c.start(sessionName: "semicolyn-a3f7c2e9")
        _ = c.feed(bytes("%exit\n"))
        XCTAssertEqual(c.lifecycle, .exited(reason: nil))
    }

    // MARK: submit gating

    func testSubmitRefusedBeforeAttached() {
        let c = TmuxSessionController()
        _ = c.start(sessionName: "semicolyn-a3f7c2e9")
        XCTAssertNil(c.submit(TmuxCommand.newWindow()), "submit before attach must be refused")
    }

    func testSubmitRefusedAfterExit() {
        let c = attachedController()
        _ = c.feed(bytes("%exit\n"))
        XCTAssertNil(c.submit("new-window"), "must not send commands to an exited session")
    }

    func testSubmitFramesWireBytesWithNewline() {
        let c = TmuxSessionController()
        _ = c.start(sessionName: "semicolyn-a3f7c2e9")
        _ = c.feed(bytes("%session-changed $7 semicolyn-a3f7c2e9\n"))
        let sub = c.submit("new-window")
        XCTAssertNotNil(sub)
        XCTAssertEqual(sub!.wire, bytes("new-window\n"), "wire must be the line plus exactly one \\n")
        XCTAssertEqual(sub!.id, 0, "first submitted command gets id 0")
    }

    func testSubmitIdsAreMonotonic() {
        let c = attachedController()
        XCTAssertEqual(c.submit("new-window")?.id, 0)
        XCTAssertEqual(c.submit("kill-pane -t %1")?.id, 1)
        XCTAssertEqual(c.submit("select-pane -t %2")?.id, 2)
    }

    // MARK: command ↔ result correlation (FIFO)

    func testCommandResultsResolveInFifoOrder() {
        let c = attachedController()
        let a = c.submit("new-window")!
        let b = c.submit("split-window -h -t %1")!
        // tmux replies in send order: a's block first, then b's.
        let out1 = c.feed(bytes("%begin 100 5 1\n%end 100 5 1\n"))
        XCTAssertEqual(out1.resolved, [ResolvedCommand(id: a.id, outcome: .ok([]))])
        let out2 = c.feed(bytes("%begin 101 6 1\n%end 101 6 1\n"))
        XCTAssertEqual(out2.resolved, [ResolvedCommand(id: b.id, outcome: .ok([]))])
    }

    func testResultBlockSplitAcrossFeedsResolvesOnEnd() {
        // The parser buffers partial lines; the result resolves only when %end lands.
        let c = attachedController()
        let a = c.submit("list-windows")!
        let out1 = c.feed(bytes("%begin 1 5 1\npartial-li"))
        XCTAssertEqual(out1.resolved, [], "no resolution until the block closes")
        let out2 = c.feed(bytes("ne\n%end 1 5 1\n"))
        XCTAssertEqual(out2.resolved,
                       [ResolvedCommand(id: a.id, outcome: .ok(["partial-line"]))])
    }

    func testCommandResultCarriesErrorOutcome() {
        let c = attachedController()
        let a = c.submit("split-window -h -t %99")!
        let out = c.feed(bytes("%begin 100 5 1\ncan't find pane %99\n%error 100 5 1\n"))
        XCTAssertEqual(out.resolved,
                       [ResolvedCommand(id: a.id, outcome: .error(["can't find pane %99"]))])
    }

    func testCommandResultBodyLinesCaptured() {
        let c = attachedController()
        let a = c.submit("list-windows")!
        let out = c.feed(bytes("%begin 1 5 1\nline-one\nline-two\n%end 1 5 1\n"))
        XCTAssertEqual(out.resolved,
                       [ResolvedCommand(id: a.id, outcome: .ok(["line-one", "line-two"]))])
    }

    func testUnsolicitedBlockDuringAttachIsDropped() {
        // The initial -CC attach block arrives with no pending command: must not
        // crash, must resolve nothing.
        let c = TmuxSessionController()
        _ = c.start(sessionName: "semicolyn-a3f7c2e9")
        let out = c.feed(bytes("%begin 1 0 1\n%end 1 0 1\n"))
        XCTAssertEqual(out.resolved, [], "spontaneous block must not be matched to a command")
    }

    func testResultWithEmptyQueueAfterAttachIsDropped() {
        // Defensive: a stray block when nothing is pending resolves nothing.
        let c = attachedController()
        let out = c.feed(bytes("%begin 1 9 1\n%end 1 9 1\n"))
        XCTAssertEqual(out.resolved, [])
    }

    // MARK: state folding

    func testStructuralEventFoldsIntoStateAndFlagsChange() {
        let c = attachedController()
        let out = c.feed(bytes("%window-add @3\n"))
        XCTAssertTrue(out.stateChanged)
        XCTAssertEqual(c.state.windows.map(\.id), [WindowID(raw: 3)])
    }

    func testNonStructuralOutputDoesNotFlagStateChange() {
        let c = attachedController()
        // %output is non-structural: it carries pane bytes, not session topology.
        let out = c.feed(bytes("%output %1 hello\n"))
        XCTAssertFalse(out.stateChanged, "%output must not flag a structural state change")
        XCTAssertFalse(out.lifecycleChanged)
    }

    // MARK: attach-prime commands

    func testFeedEmitsPrimeCommandsOnAttachEdgeOnce() {
        let c = TmuxSessionController()
        _ = c.start(sessionName: "semicolyn-a3f7c2e9")
        // Before attach: a spontaneous result block arrives — no prime yet.
        let pre = c.feed(bytes("%begin 1 0 1\n%end 1 0 1\n"))
        XCTAssertTrue(pre.attachedPrimeCommands.isEmpty)
        // The %session-changed that flips .attaching → .attached.
        let atEdge = c.feed(bytes("%session-changed $7 semicolyn-a3f7c2e9\n"))
        XCTAssertEqual(atEdge.attachedPrimeCommands,
                       ["refresh-client -C 80x24",
                        TmuxCommand.listWindowsForLayout()])
        // A later feed does NOT re-emit the prime.
        let after = c.feed(bytes("%window-add @0\n"))
        XCTAssertTrue(after.attachedPrimeCommands.isEmpty)
    }

    // MARK: applyEvents

    func testApplyEventsPopulatesWindowsAndLayout() {
        let c = TmuxSessionController()
        let win = ParsedWindow(id: WindowID(raw: 0), active: true,
                               layout: PaneLayout.parse("abcd,80x24,0,0,0")!)
        let changed = c.applyEvents(windowListingEvents([win], sessionID: SessionID(raw: 0)))
        XCTAssertTrue(changed)
        XCTAssertEqual(c.state.windows.count, 1)
        XCTAssertEqual(c.state.activeWindow, WindowID(raw: 0))
        XCTAssertNotNil(c.state.window(WindowID(raw: 0))?.visibleLayout)
    }

    /// Reattach regression: the attach-time layout prime must set each window's
    /// ACTIVE PANE (from its layout), not just the layout. Without it `activePane`
    /// is nil, so `TmuxRuntime.sendInput` drops every keystroke (send-keys has no
    /// target) — the "reattach, terminal renders, but typing does nothing" bug.
    /// Layout "abcd,80x24,0,0,0" → single leaf PaneID(raw: 0).
    func testApplyEventsSetsActivePaneFromLayout() {
        let c = TmuxSessionController()
        let win = ParsedWindow(id: WindowID(raw: 0), active: true,
                               layout: PaneLayout.parse("abcd,80x24,0,0,0")!)
        _ = c.applyEvents(windowListingEvents([win], sessionID: SessionID(raw: 0)))
        XCTAssertEqual(c.state.window(WindowID(raw: 0))?.activePane, PaneID(raw: 0),
                       "Reattach prime must set the active window's activePane to its layout's pane")
    }

    // MARK: helpers

    private func attachedController() -> TmuxSessionController {
        let c = TmuxSessionController()
        _ = c.start(sessionName: "semicolyn-a3f7c2e9")
        _ = c.feed(Array("%session-changed $7 semicolyn-a3f7c2e9\n".utf8))
        return c
    }
}
