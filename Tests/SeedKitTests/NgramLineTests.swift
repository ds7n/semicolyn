// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SeedKit

final class NgramLineTests: XCTestCase {
    func p(_ s: String) -> NgramLine? { parseNgramLine(Substring(s), minYear: 1990) }

    func testSumsYearsFromMinYear() {
        XCTAssertEqual(p("the cat\t1989,5,1\t1990,7,2\t2019,3,1"), NgramLine(tokens: ["the", "cat"], count: 10))
        XCTAssertEqual(p("x's\t2000,5,1"), NgramLine(tokens: ["x's"], count: 5))
        XCTAssertEqual(p("Linux\t1990,1,1"), NgramLine(tokens: ["Linux"], count: 1))   // boundary year kept
        XCTAssertNil(p("Linux\t1989,1,1"))                                              // boundary - 1 dropped
    }

    func testRejections() {
        XCTAssertNil(p("the_DET\t2000,9,1"))
        XCTAssertNil(p("_NOUN_\t2000,9,1"))
        XCTAssertNil(p("the _NOUN_\t2000,9,1"))     // one bad token poisons the ngram
        XCTAssertNil(p("123\t2000,5,1"))
        XCTAssertNil(p("the 123\t2000,5,1"))
        XCTAssertNil(p("abc"))
        XCTAssertNil(p("old\t1989,5,1"))            // only years before 1990
        XCTAssertNil(p("bad\t2000,x,1\t2001,,1"))   // every entry malformed
        XCTAssertNil(p("zero\t2000,0,1"))           // sum of 0
    }

    func testMalformedEntriesSkipped() {
        XCTAssertEqual(p("ok\t2000,x,1\t2001,4,1"), NgramLine(tokens: ["ok"], count: 4))
        XCTAssertEqual(p("ok\tyear,3,1\t2001,-4,1\t2002,6,1"), NgramLine(tokens: ["ok"], count: 6))
    }

    func testCountSaturatesInsteadOfTrapping() {
        let big = String(UInt64.max)
        XCTAssertEqual(p("big\t2000,\(big),1\t2001,5,1"), NgramLine(tokens: ["big"], count: UInt64.max))
    }

    // MARK: - stream filter

    private func run(_ chunks: [String], vocab: Set<String>? = nil, minCount: UInt64 = 40) -> String {
        var f = NgramStreamFilter(minYear: 1990, minCount: minCount, vocab: vocab)
        var out: [UInt8] = []
        for c in chunks { f.feed(Array(c.utf8), into: &out) }
        f.finish(into: &out)
        return String(decoding: out, as: UTF8.self)
    }

    func testFilterOutputFormatAndMinCountBoundary() {
        let input = "the cat\t2000,50,1\nthe_DET\t2000,9,1\nat 40\t2000,40,1\njust below\t2000,39,1\n"
        XCTAssertEqual(run([input]), "the cat\t50\n")   // "at 40" has a digit-only token
        let input2 = "edge\t2000,40,1\nunder\t2000,39,1\n"
        XCTAssertEqual(run([input2]), "edge\t40\n")
    }

    func testFilterVocabRequiresEveryTokenLowercased() {
        let vocab: Set<String> = ["the", "cat"]
        let input = "The Cat\t2000,50,1\nthe dog\t2000,50,1\ncat\t2000,50,1\n"
        XCTAssertEqual(run([input], vocab: vocab), "The Cat\t50\ncat\t50\n")
    }

    func testFilterHandlesLinesSplitAcrossChunksAndMissingTrailingNewline() {
        let whole = "the cat\t2000,50,1\nthe dog\t2000,60,1"
        XCTAssertEqual(run(["the c", "at\t2000,5", "0,1\nthe dog\t20", "00,60,1"]), "the cat\t50\nthe dog\t60\n")
        XCTAssertEqual(run([whole]), "the cat\t50\nthe dog\t60\n")
    }

    func testFilterSplitsMultiByteCharacterAcrossChunks() {
        let bytes = Array("café au\t2000,50,1\n".utf8)
        var f = NgramStreamFilter(minYear: 1990, minCount: 1, vocab: nil)
        var out: [UInt8] = []
        f.feed(Array(bytes[0..<4]), into: &out)   // splits inside the two-byte "é"
        f.feed(Array(bytes[4...]), into: &out)
        f.finish(into: &out)
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "café au\t50\n")
    }

    func testFilterToleratesCRLF() {
        XCTAssertEqual(run(["the cat\t2000,50,1\r\n"]), "the cat\t50\n")
    }
}
