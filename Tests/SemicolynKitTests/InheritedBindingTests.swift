// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

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

    // MARK: - textToInheritedInt(minimum: 0) — serverAlive fields
    //
    // For ServerAliveInterval/CountMax, `0` is a meaningful value (OpenSSH:
    // keepalives disabled), so those bindings pass `minimum: 0`. The boundary is
    // the whole point of the fix — a user typing `0` must reach `.explicit(0)`,
    // not silently become `.inherit`.

    func testZeroWithMinimumZeroBecomesExplicitZero() {
        // BVA at the boundary: 0 is accepted when minimum is 0.
        XCTAssertEqual(textToInheritedInt("0", minimum: 0), .explicit(0))
    }

    func testZeroWithDefaultMinimumStillInherits() {
        // Contrast: the same "0" is rejected under the default (port) minimum,
        // so the port field's behavior is unchanged by the new parameter.
        XCTAssertEqual(textToInheritedInt("0"), .inherit)
    }

    func testPositiveWithMinimumZeroBecomesExplicit() {
        XCTAssertEqual(textToInheritedInt("30", minimum: 0), .explicit(30))
    }

    func testNegativeWithMinimumZeroStillInherits() {
        // min−1 boundary: negatives are rejected even at minimum 0.
        XCTAssertEqual(textToInheritedInt("-1", minimum: 0), .inherit)
    }

    func testEmptyWithMinimumZeroInherits() {
        // An empty serverAlive field still means "inherit", not "0/disabled".
        XCTAssertEqual(textToInheritedInt("", minimum: 0), .inherit)
    }

    // MARK: - inheritedBoolToSelection

    func testBoolInheritYieldsNilSelection() {
        XCTAssertNil(inheritedBoolToSelection(.inherit))
    }

    func testBoolExplicitNilYieldsNilSelection() {
        XCTAssertNil(inheritedBoolToSelection(.explicit(nil)))
    }

    func testBoolExplicitTrueYieldsTrue() {
        XCTAssertEqual(inheritedBoolToSelection(.explicit(true)), true)
    }

    func testBoolExplicitFalseYieldsFalse() {
        XCTAssertEqual(inheritedBoolToSelection(.explicit(false)), false)
    }

    // MARK: - selectionToInheritedBool

    func testNilSelectionBecomesInheritBool() {
        XCTAssertEqual(selectionToInheritedBool(nil), .inherit)
    }

    func testTrueSelectionBecomesExplicitTrue() {
        XCTAssertEqual(selectionToInheritedBool(true), .explicit(true))
    }

    func testFalseSelectionBecomesExplicitFalse() {
        XCTAssertEqual(selectionToInheritedBool(false), .explicit(false))
    }

    func testBoolRoundTripInherit() {
        XCTAssertEqual(selectionToInheritedBool(inheritedBoolToSelection(.inherit)), .inherit)
    }

    func testBoolRoundTripExplicitTrue() {
        XCTAssertEqual(selectionToInheritedBool(inheritedBoolToSelection(.explicit(true))), .explicit(true))
    }

    func testBoolRoundTripExplicitFalse() {
        XCTAssertEqual(selectionToInheritedBool(inheritedBoolToSelection(.explicit(false))), .explicit(false))
    }

    /// `.explicit(nil)` has no distinct Picker representation; it collapses to `.inherit` on round-trip — intentional.
    func testBoolExplicitNilRoundTripCollapsesToInherit() {
        XCTAssertEqual(selectionToInheritedBool(inheritedBoolToSelection(.explicit(nil))), .inherit)
    }

    /// Three-state discipline: explicit(false) must not collapse to inherit.
    func testExplicitFalseIsDistinctFromInherit() {
        let fromFalse = selectionToInheritedBool(inheritedBoolToSelection(.explicit(false)))
        let fromInherit = selectionToInheritedBool(inheritedBoolToSelection(.inherit))
        XCTAssertNotEqual(fromFalse, fromInherit)
    }

    // MARK: - inheritedSHKCToSelection

    func testSHKCInheritYieldsNilSelection() {
        XCTAssertNil(inheritedSHKCToSelection(.inherit))
    }

    func testSHKCExplicitNilYieldsNilSelection() {
        XCTAssertNil(inheritedSHKCToSelection(.explicit(nil)))
    }

    func testSHKCExplicitYesYieldsYes() {
        XCTAssertEqual(inheritedSHKCToSelection(.explicit(.yes)), .yes)
    }

    func testSHKCExplicitNoYieldsNo() {
        XCTAssertEqual(inheritedSHKCToSelection(.explicit(.no)), .no)
    }

    func testSHKCExplicitAcceptNewYieldsAcceptNew() {
        XCTAssertEqual(inheritedSHKCToSelection(.explicit(.acceptNew)), .acceptNew)
    }

    func testSHKCExplicitAskYieldsAsk() {
        XCTAssertEqual(inheritedSHKCToSelection(.explicit(.ask)), .ask)
    }

    // MARK: - selectionToInheritedSHKC

    func testNilSHKCSelectionBecomesInherit() {
        XCTAssertEqual(selectionToInheritedSHKC(nil), .inherit)
    }

    func testSHKCSelectionYesBecomesExplicitYes() {
        XCTAssertEqual(selectionToInheritedSHKC(.yes), .explicit(.yes))
    }

    /// `.explicit(nil)` has no distinct Picker representation; it collapses to `.inherit` on round-trip — intentional.
    func testSHKCExplicitNilRoundTripCollapsesToInherit() {
        XCTAssertEqual(selectionToInheritedSHKC(inheritedSHKCToSelection(.explicit(nil))), .inherit)
    }

    func testSHKCRoundTripInherit() {
        XCTAssertEqual(selectionToInheritedSHKC(inheritedSHKCToSelection(.inherit)), .inherit)
    }

    func testSHKCRoundTripExplicit() {
        for c: StrictHostKeyChecking in [.yes, .acceptNew, .ask, .no] {
            XCTAssertEqual(selectionToInheritedSHKC(inheritedSHKCToSelection(.explicit(c))), .explicit(c))
        }
    }

    // MARK: - inheritedAuthMethodsToSelection

    func testAuthMethodsInheritYieldsNilSelection() {
        XCTAssertNil(inheritedAuthMethodsToSelection(.inherit))
    }

    func testAuthMethodsExplicitNilYieldsNilSelection() {
        XCTAssertNil(inheritedAuthMethodsToSelection(.explicit(nil)))
    }

    func testAuthMethodsExplicitEmptyYieldsEmptySet() {
        XCTAssertEqual(inheritedAuthMethodsToSelection(.explicit([])), Set<AuthMethod>())
    }

    func testAuthMethodsExplicitSingleYieldsSingletonSet() {
        XCTAssertEqual(inheritedAuthMethodsToSelection(.explicit([.publicKey])), Set([.publicKey]))
    }

    func testAuthMethodsExplicitMultipleYieldsFullSet() {
        let result = inheritedAuthMethodsToSelection(.explicit([.publicKey, .password]))
        XCTAssertEqual(result, Set([.publicKey, .password]))
    }

    // MARK: - selectionToInheritedAuthMethods

    func testNilAuthSelectionBecomesInherit() {
        XCTAssertEqual(selectionToInheritedAuthMethods(nil), .inherit)
    }

    func testEmptySetBecomesExplicitEmpty() {
        XCTAssertEqual(selectionToInheritedAuthMethods(Set<AuthMethod>()), .explicit([]))
    }

    func testAuthMethodsCanonicalOrder() {
        // Input order irrelevant; output must be canonical: publicKey, password, keyboardInteractive.
        let result = selectionToInheritedAuthMethods(Set([.keyboardInteractive, .publicKey, .password]))
        XCTAssertEqual(result, .explicit([.publicKey, .password, .keyboardInteractive]))
    }

    /// `.explicit(nil)` has no distinct Picker representation; it collapses to `.inherit` on round-trip — intentional.
    func testAuthMethodsExplicitNilRoundTripCollapsesToInherit() {
        XCTAssertEqual(selectionToInheritedAuthMethods(inheritedAuthMethodsToSelection(.explicit(nil))), .inherit)
    }

    func testAuthMethodsRoundTripInherit() {
        XCTAssertEqual(selectionToInheritedAuthMethods(inheritedAuthMethodsToSelection(.inherit)), .inherit)
    }

    func testAuthMethodsRoundTripExplicit() {
        // All three — canonical order preserved through round-trip.
        let input: Inherited<[AuthMethod]> = .explicit([.publicKey, .password, .keyboardInteractive])
        let out = selectionToInheritedAuthMethods(inheritedAuthMethodsToSelection(input))
        XCTAssertEqual(out, input)
    }

    /// Three-state discipline: explicit([]) must not collapse to inherit.
    func testExplicitEmptyAuthMethodsIsDistinctFromInherit() {
        XCTAssertNotEqual(
            selectionToInheritedAuthMethods(Set<AuthMethod>()),
            selectionToInheritedAuthMethods(nil)
        )
    }
}
