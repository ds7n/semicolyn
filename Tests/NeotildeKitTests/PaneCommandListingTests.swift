// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import NeotildeKit

final class PaneCommandListingTests: XCTestCase {
    func testParsesPaneIDAndCommand() {
        let parsed = parsePaneCommandListing(["%0 zsh", "%3 vim", "%12 python3"])
        XCTAssertEqual(parsed.count, 3)
        XCTAssertEqual(parsed[0].0, PaneID(raw: 0)); XCTAssertEqual(parsed[0].1, "zsh")
        XCTAssertEqual(parsed[1].0, PaneID(raw: 3)); XCTAssertEqual(parsed[1].1, "vim")
        XCTAssertEqual(parsed[2].0, PaneID(raw: 12)); XCTAssertEqual(parsed[2].1, "python3")
    }

    func testCommandWithSpacesKeepsTail() {
        let parsed = parsePaneCommandListing(["%1 ruby script.rb"])
        XCTAssertEqual(parsed.first?.1, "ruby script.rb")  // only the first space splits
    }

    func testSkipsMalformedAndEmptyLines() {
        let parsed = parsePaneCommandListing(["", "garbage", "@7 notapane", "%2", "%4 bash"])
        // "" / "garbage" / "@7 …" (wrong sigil) / "%2" (no command) all rejected.
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.first?.0, PaneID(raw: 4))
        XCTAssertEqual(parsed.first?.1, "bash")
    }
}
