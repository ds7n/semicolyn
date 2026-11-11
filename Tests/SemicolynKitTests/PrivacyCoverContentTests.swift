// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class PrivacyCoverContentTests: XCTestCase {
    private func content(label: String, hostName: String, _ transport: Transport) -> PrivacyCoverContent {
        privacyCoverContent(CoverSession(label: label, hostName: hostName, transport: transport))
    }

    func testNoSession() {
        XCTAssertEqual(privacyCoverContent(nil),
                       PrivacyCoverContent(title: nil, subtitle: "No session open"))
    }

    func testSavedHost() {
        XCTAssertEqual(content(label: "work box", hostName: "10.0.0.5", .mosh),
                       PrivacyCoverContent(title: "work box", subtitle: "Mosh"))
        XCTAssertEqual(content(label: "work box", hostName: "10.0.0.5", .ssh).subtitle, "SSH")
        XCTAssertEqual(content(label: "work box", hostName: "10.0.0.5", .et).subtitle, "ET")
    }

    func testLabelMatchingAddressIsHidden() {
        let cases: [(label: String, hostName: String)] = [
            (" Example.COM ", "example.com"),
            ("10.0.0.5", "10.0.0.5"),
            ("", "10.0.0.5"),
            ("   ", "10.0.0.5"),
        ]
        for c in cases {
            let result = content(label: c.label, hostName: c.hostName, .ssh)
            XCTAssertEqual(result, PrivacyCoverContent(title: "Quick connect", subtitle: "SSH"),
                           "label \(c.label.debugDescription)")
            XCTAssertFalse(result.title?.contains(c.hostName) ?? false)
        }
    }

    func testLabelContainingButNotEqualToAddressIsKept() {
        XCTAssertEqual(content(label: "box 10.0.0.5", hostName: "10.0.0.5", .ssh).title,
                       "box 10.0.0.5")
    }
}
