// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class ETBootstrapMaskTests: XCTestCase {
    private let id16 = "abcdef0123456789"
    private let key32 = "0123456789abcdef0123456789abcdef"

    // The actual credential characters must NEVER appear in the masked output.
    func testCredentialValuesAreAbsent() {
        let out = maskBootstrapPayload("IDPASSKEY:\(id16)/\(key32)\n")
        XCTAssertFalse(out.contains(id16), "id leaked into masked output")
        XCTAssertFalse(out.contains(key32), "passkey leaked into masked output")
    }

    // Structure (marker, lengths, slash) is shown.
    func testStructureShown() {
        let out = maskBootstrapPayload("IDPASSKEY:\(id16)/\(key32)\n")
        XCTAssertTrue(out.contains("IDPASSKEY:"))
        XCTAssertTrue(out.contains("<id:16>"))
        XCTAssertTrue(out.contains("<key:32>"))
    }

    // Trailing junk (the bug signature) is visible, control chars as repr.
    func testTrailingJunkVisible() {
        let out = maskBootstrapPayload("IDPASSKEY:\(id16)/\(key32)\r extra=1")
        XCTAssertTrue(out.contains("trailing="), "trailing content not surfaced")
        XCTAssertTrue(out.contains("\\r"), "CR not shown as repr")
        XCTAssertTrue(out.contains("extra=1"))
    }

    // Leading banner before the marker is visible.
    func testLeadingBannerVisible() {
        let out = maskBootstrapPayload("bash: no tty\nIDPASSKEY:\(id16)/\(key32)\n")
        XCTAssertTrue(out.contains("leading="))
        XCTAssertTrue(out.contains("bash: no tty"))
    }

    // No marker: content repr, no crash, no credential (there is none).
    func testNoMarker() {
        let out = maskBootstrapPayload("command not found: etterminal\n")
        XCTAssertTrue(out.contains("no-marker"))
        XCTAssertTrue(out.contains("command not found"))
    }
}
