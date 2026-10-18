// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class WordShapeTests: XCTestCase {
    func testLookupWordTrimsPunctuation() {
        XCTAssertEqual(lookupWord(fromToken: "(including"), LookupWord(leading: "(", word: "including", trailing: ""))
        XCTAssertEqual(lookupWord(fromToken: "me,"), LookupWord(leading: "", word: "me", trailing: ","))
        XCTAssertEqual(lookupWord(fromToken: "\"done.\""), LookupWord(leading: "\"", word: "done", trailing: ".\""))
        XCTAssertEqual(lookupWord(fromToken: "e.g."), LookupWord(leading: "", word: "e.g", trailing: "."))
        XCTAssertEqual(lookupWord(fromToken: "don't"), LookupWord(leading: "", word: "don't", trailing: ""))
    }

    func testLookupWordKeepsPathAndFlagTokens() {
        for t in ["./x", "--opt=val", "~/a", "a/b", "-", "/usr", "../up"] {
            XCTAssertEqual(lookupWord(fromToken: t), LookupWord(leading: "", word: t, trailing: ""), t)
        }
    }

    func testLookupWordBoundaries() {
        XCTAssertEqual(lookupWord(fromToken: ""), LookupWord(leading: "", word: "", trailing: ""))
        XCTAssertEqual(lookupWord(fromToken: "(("), LookupWord(leading: "((", word: "", trailing: ""))
        XCTAssertEqual(lookupWord(fromToken: "a"), LookupWord(leading: "", word: "a", trailing: ""))
    }

    func testCaseMatching() {
        XCTAssertEqual(caseMatchedForm(typed: "lin", candidate: "Linux"), "Linux")
        XCTAssertEqual(caseMatchedForm(typed: "lin", candidate: "linux"), "linux")
        XCTAssertEqual(caseMatchedForm(typed: "Lin", candidate: "linux"), "Linux")
        XCTAssertEqual(caseMatchedForm(typed: "Th", candidate: "the"), "The")
        XCTAssertEqual(caseMatchedForm(typed: "Th", candidate: "Thursday"), "Thursday")
        XCTAssertEqual(caseMatchedForm(typed: "th", candidate: "Thursday"), "Thursday")
        XCTAssertEqual(caseMatchedForm(typed: "AP", candidate: "API"), "API")
        XCTAssertEqual(caseMatchedForm(typed: "Ap", candidate: "apple"), "Apple")
        XCTAssertEqual(caseMatchedForm(typed: "api", candidate: "API"), "API")
        XCTAssertEqual(caseMatchedForm(typed: "i", candidate: "I"), "I")
        XCTAssertEqual(caseMatchedForm(typed: "", candidate: "the"), "the")
    }

    func testCaseMismatchesReturnNil() {
        XCTAssertNil(caseMatchedForm(typed: "AP", candidate: "apple"))
        XCTAssertNil(caseMatchedForm(typed: "LIN", candidate: "Linux"))
        XCTAssertNil(caseMatchedForm(typed: "IP", candidate: "iPhone"))
        XCTAssertNil(caseMatchedForm(typed: "linux", candidate: "lin"))
        XCTAssertNil(caseMatchedForm(typed: "x", candidate: ""))
        XCTAssertNil(caseMatchedForm(typed: "tx", candidate: "the"))
    }

    func testNonASCII() {
        XCTAssertEqual(caseMatchedForm(typed: "é", candidate: "École"), "École")
        XCTAssertEqual(caseMatchedForm(typed: "Éc", candidate: "école"), "École")
        XCTAssertEqual(lookupWord(fromToken: "“quoted”"), LookupWord(leading: "“", word: "quoted", trailing: "”"))
        XCTAssertEqual(lookupWord(fromToken: "🙂"), LookupWord(leading: "", word: "🙂", trailing: ""))
    }
}
