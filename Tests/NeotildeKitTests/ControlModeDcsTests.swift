// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import NeotildeKit

/// DCS-envelope stripping. Real `tmux -CC` wraps the whole control stream in
/// `ESC P1000p … ESC \`, with the intro glued to the first `%begin`. The parser
/// must strip this framing or it mis-parses the first and last lines. Input here
/// mirrors the bytes captured from a live `tmux -CC` session in the sshd fixture.
final class ControlModeDcsTests: XCTestCase {
    private func feed(_ p: ControlModeParser, _ s: String) -> [ControlModeEvent] {
        p.feed(Array(s.utf8))
    }

    func testStripsIntroGluedToFirstBegin() {
        // Without stripping, the first line is "\u{1b}P1000p%begin …", which does
        // not match the "%begin " prefix, so the block never opens.
        let p = ControlModeParser()
        let events = feed(p, "\u{1b}P1000p%begin 1781968446 264 0\r\n%end 1781968446 264 0\r\n")
        XCTAssertEqual(events, [.commandResult(number: 264, outcome: .ok([]))])
    }

    func testIntroOnlyLineProducesNoEvent() {
        // A bare intro line strips to empty and must not become a malformed event.
        let p = ControlModeParser()
        XCTAssertEqual(feed(p, "\u{1b}P1000p\r\n"), [])
    }

    func testBareTerminatorIsDroppedAndDoesNotPolluteBuffer() {
        let p = ControlModeParser()
        // ST arrives with no trailing newline (as real tmux emits it after %exit).
        XCTAssertEqual(feed(p, "\u{1b}\\"), [])
        // The next real line must still parse — proving the buffer was cleared,
        // not left holding the two ST bytes.
        XCTAssertEqual(feed(p, "%window-add @1\n"), [.windowAdd(WindowID(raw: 1))])
    }

    func testTerminatorSplitAcrossFeedsStillClears() {
        let p = ControlModeParser()
        XCTAssertEqual(feed(p, "\u{1b}"), [])      // ESC alone — incomplete, buffered
        XCTAssertEqual(feed(p, "\\"), [])          // backslash completes the ST → cleared
        XCTAssertEqual(feed(p, "%window-add @2\n"), [.windowAdd(WindowID(raw: 2))])
    }

    func testIntroSplitAcrossFeeds() {
        let p = ControlModeParser()
        XCTAssertEqual(feed(p, "\u{1b}P1000p%be"), [])  // line not yet complete
        let events = feed(p, "gin 1 264 0\r\n%end 1 264 0\r\n")
        XCTAssertEqual(events, [.commandResult(number: 264, outcome: .ok([]))])
    }

    func testFullRealHandshakeParses() {
        // The exact event sequence a fresh `tmux -CC new-session -A -s neotilde-test`
        // attach emits, DCS-wrapped, CRLF line endings, trailing ST.
        let p = ControlModeParser()
        let stream =
            "\u{1b}P1000p%begin 1 264 0\r\n" +
            "%end 1 264 0\r\n" +
            "%window-add @0\r\n" +
            "%sessions-changed\r\n" +
            "%session-changed $0 neotilde-test\r\n" +
            "%exit\r\n" +
            "\u{1b}\\"
        let events = feed(p, stream)
        XCTAssertEqual(events, [
            .commandResult(number: 264, outcome: .ok([])),
            .windowAdd(WindowID(raw: 0)),
            .sessionsChanged,
            .sessionChanged(SessionID(raw: 0), name: "neotilde-test"),
            .exit(reason: nil),
        ])
    }

    func testUnwrappedInputUnaffected() {
        // Regression: input without any DCS framing parses exactly as before —
        // the strip is a no-op.
        let p = ControlModeParser()
        XCTAssertEqual(feed(p, "%window-add @5\n"), [.windowAdd(WindowID(raw: 5))])
    }
}
