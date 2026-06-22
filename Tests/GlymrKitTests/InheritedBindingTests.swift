// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import GlymrKit

/// Verifies the pure `String ↔ Inherited<T>` conversion helpers used by
/// `HostEditorView` bindings. These must be correct because any three-state
/// collapse (e.g., empty → `.explicit(nil)` instead of `.inherit`) silently
/// corrupts host records.
final class InheritedBindingTests: XCTestCase {

    // MARK: - inheritedStringToText

    func testInheritYieldsEmptyString() {
        XCTAssertEqual(inheritedStringToText(.inherit), "")
    }

    func testExplicitNilYieldsEmptyString() {
        XCTAssertEqual(inheritedStringToText(.explicit(nil)), "")
    }

    func testExplicitValueYieldsItsString() {
        XCTAssertEqual(inheritedStringToText(.explicit("root")), "root")
    }

    // MARK: - textToInheritedString

    func testEmptyTextBecomesInherit() {
        XCTAssertEqual(textToInheritedString(""), .inherit)
    }

    func testNonEmptyTextBecomesExplicit() {
        XCTAssertEqual(textToInheritedString("root"), .explicit("root"))
    }

    func testRoundTripInherit() {
        let out: Inherited<String> = textToInheritedString(inheritedStringToText(.inherit))
        XCTAssertEqual(out, .inherit)
    }

    func testRoundTripExplicit() {
        let out: Inherited<String> = textToInheritedString(inheritedStringToText(.explicit("ubuntu")))
        XCTAssertEqual(out, .explicit("ubuntu"))
    }

    // MARK: - inheritedIntToText

    func testIntInheritYieldsEmptyString() {
        XCTAssertEqual(inheritedIntToText(.inherit), "")
    }

    func testIntExplicitNilYieldsEmptyString() {
        XCTAssertEqual(inheritedIntToText(.explicit(nil)), "")
    }

    func testIntExplicitValueYieldsDecimalString() {
        XCTAssertEqual(inheritedIntToText(.explicit(22)), "22")
        XCTAssertEqual(inheritedIntToText(.explicit(2222)), "2222")
    }

    // MARK: - textToInheritedInt

    func testEmptyPortTextBecomesInherit() {
        XCTAssertEqual(textToInheritedInt(""), .inherit)
    }

    func testNumericPortTextBecomesExplicit() {
        XCTAssertEqual(textToInheritedInt("22"), .explicit(22))
        XCTAssertEqual(textToInheritedInt("2222"), .explicit(2222))
    }

    func testNonNumericPortTextBecomesInherit() {
        // A user accidentally types letters; silently inherit rather than crash.
        XCTAssertEqual(textToInheritedInt("abc"), .inherit)
    }

    func testZeroPortTextBecomesInherit() {
        // Port 0 is not a valid SSH port; treat as un-set.
        XCTAssertEqual(textToInheritedInt("0"), .inherit)
    }

    func testNegativePortTextBecomesInherit() {
        XCTAssertEqual(textToInheritedInt("-1"), .inherit)
    }

    func testRoundTripIntInherit() {
        let out: Inherited<Int> = textToInheritedInt(inheritedIntToText(.inherit))
        XCTAssertEqual(out, .inherit)
    }

    func testRoundTripIntExplicit() {
        let out: Inherited<Int> = textToInheritedInt(inheritedIntToText(.explicit(22)))
        XCTAssertEqual(out, .explicit(22))
    }
}
