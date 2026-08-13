// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class TokenFilterBlocklistTests: XCTestCase {
    private let filter = TokenFilter(patterns: [.blocklist(["badword", "slur"])])

    func testExcludesExactBlocklistedToken() {
        XCTAssertTrue(filter.excludes("badword"))
        XCTAssertTrue(filter.excludes("slur"))
    }

    func testCaseInsensitive() {
        XCTAssertTrue(filter.excludes("BadWord"))
        XCTAssertTrue(filter.excludes("SLUR"))
    }

    func testDoesNotSubstringMatch() {
        // Scunthorpe guard: a clean word CONTAINING a blocked word is NOT excluded.
        XCTAssertFalse(filter.excludes("badwording"))
        XCTAssertFalse(filter.excludes("aslurp"))
    }

    func testCleanTokenNotExcluded() {
        XCTAssertFalse(filter.excludes("commit"))
        XCTAssertFalse(filter.excludes("kill"))   // shell-legit, must survive
    }
}
