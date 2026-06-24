// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import NeotildeKit

final class TmuxControllerOutputTests: XCTestCase {
    /// Drives the controller through a minimal attach so it is `.attached`, then
    /// feeds a `%output` line and asserts the bytes surface on `paneOutput`.
    func testFeedSurfacesPaneOutputBytes() {
        let c = TmuxSessionController()
        _ = c.start(sessionName: "neotilde-test")
        // Attach handshake: a spontaneous %begin/%end block + %session-changed.
        _ = c.feed(Array("\u{1b}P1000p%begin 1 0\r\n%end 1 0\r\n%session-changed $1 neotilde-test\r\n".utf8))

        // tmux escapes output octally; "hi" is plain ASCII so it passes through.
        let out = c.feed(Array("%output %1 hi\r\n".utf8))

        XCTAssertEqual(out.paneOutput.count, 1)
        XCTAssertEqual(out.paneOutput.first?.pane, PaneID(raw: 1))
        XCTAssertEqual(out.paneOutput.first?.data, Array("hi".utf8))
    }

    /// A feed with no %output yields an empty paneOutput (not nil, not garbage).
    func testFeedWithoutOutputHasEmptyPaneOutput() {
        let c = TmuxSessionController()
        _ = c.start(sessionName: "neotilde-test")
        let out = c.feed(Array("\u{1b}P1000p%begin 1 0\r\n%end 1 0\r\n%session-changed $1 neotilde-test\r\n".utf8))
        XCTAssertTrue(out.paneOutput.isEmpty)
    }
}
