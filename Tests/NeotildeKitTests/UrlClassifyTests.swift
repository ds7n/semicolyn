// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import NeotildeKit

final class UrlClassifyTests: XCTestCase {
    func testClassifiesAllowedSchemes() {
        XCTAssertEqual(classifyURL("https://example.com"), .https)
        XCTAssertEqual(classifyURL("http://example.com"), .http)
        XCTAssertEqual(classifyURL("ssh://user@host"), .ssh)
        XCTAssertEqual(classifyURL("HTTPS://Example.com"), .https)   // case-insensitive
        XCTAssertEqual(classifyURL("HTTP://example.com"), .http)
        XCTAssertEqual(classifyURL("SSH://user@host"), .ssh)
    }
    func testRejectsDisallowedSchemes() {
        XCTAssertNil(classifyURL("mailto:a@b.com"))
        XCTAssertNil(classifyURL("ftp://host/x"))
        XCTAssertNil(classifyURL("javascript:alert(1)"))
        XCTAssertNil(classifyURL(""))
        XCTAssertNil(classifyURL("example.com"))                     // no scheme
    }
    func testJoinsWrappedURLOnlyWhenTight() {
        XCTAssertEqual(joinWrappedURL(part1: "https://exa", part2: "mple.com"), "https://example.com")
        XCTAssertNil(joinWrappedURL(part1: "https://exa ", part2: "mple.com"))  // trailing space
        XCTAssertNil(joinWrappedURL(part1: "https://exa", part2: " mple.com"))  // leading space
        XCTAssertNil(joinWrappedURL(part1: "", part2: "mple.com"))
        XCTAssertNil(joinWrappedURL(part1: "https://exa", part2: ""))
    }
}
