// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import NeotildeKit

/// PrefixIndex — Core tier. Sorted-unique invariant + prefix lookup.
final class PrefixIndexTests: XCTestCase {
    private func index(_ tokens: [String]) -> PrefixIndex {
        var i = PrefixIndex()
        for t in tokens { i.insert(t) }
        return i
    }

    func testMatchingReturnsSortedMatches() {
        let i = index(["grep", "git", "go"])
        XCTAssertEqual(i.matching(prefix: "g"), ["git", "go", "grep"])
    }

    func testInsertDeduplicates() {
        let i = index(["git", "git", "git"])
        XCTAssertEqual(i.count, 1)
        XCTAssertEqual(i.matching(prefix: "git"), ["git"])
    }

    func testNarrowerPrefixNarrowsMatches() {
        let i = index(["git", "go", "grep", "gcc"])
        XCTAssertEqual(i.matching(prefix: "gi"), ["git"])
        XCTAssertEqual(i.matching(prefix: "g"), ["gcc", "git", "go", "grep"])
    }

    func testNoMatchReturnsEmpty() {
        let i = index(["git", "go"])
        XCTAssertEqual(i.matching(prefix: "z"), [])
    }

    func testFullTokenAsPrefixIncludesIt() {
        let i = index(["git", "github", "go"])
        XCTAssertEqual(i.matching(prefix: "git"), ["git", "github"])
    }

    func testEmptyPrefixMatchesAll() {
        let i = index(["b", "a", "c"])
        XCTAssertEqual(i.matching(prefix: ""), ["a", "b", "c"])
    }

    func testPrefixLongerThanAnyToken() {
        let i = index(["git"])
        XCTAssertEqual(i.matching(prefix: "gittttt"), [])
    }

    func testCaseSensitive() {
        let i = index(["Git", "git"])
        XCTAssertEqual(i.matching(prefix: "git"), ["git"], "lowercase prefix must not match capitalized token")
        XCTAssertEqual(i.matching(prefix: "Git"), ["Git"])
    }

    func testNonAsciiTokenPrefixMatch() {
        // Precomposed "café" sorts and prefix-matches by UTF-8 bytes.
        let i = index(["café", "cat", "cab"])
        XCTAssertEqual(i.matching(prefix: "ca"), ["cab", "caf\u{e9}", "cat"])
        XCTAssertEqual(i.matching(prefix: "caf"), ["caf\u{e9}"])
    }

    func testBytePrefixMatchesCombiningMarkTokenContiguously() {
        // "e\u{301}" is e + COMBINING ACUTE — ONE grapheme, so grapheme hasPrefix
        // would NOT match "e". Byte-prefix DOES (first byte is 0x65) and keeps the
        // matching run contiguous. This is the guarantee the byte ordering buys.
        let combining = "e\u{301}"
        let i = index(["a", combining, "ef", "z"])
        XCTAssertEqual(i.matching(prefix: "e"), ["ef", combining])
    }

    // MARK: serialization (Critical tier — blob is a synced/seed format)

    func testSerializationRoundTrip() {
        let i = index(["grep", "git", "go", "café"])
        let restored = PrefixIndex(deserializing: i.serialize())
        XCTAssertEqual(restored, i)
        XCTAssertEqual(restored?.matching(prefix: "g"), ["git", "go", "grep"])
    }

    func testEmptyIndexRoundTrip() {
        let i = PrefixIndex()
        let restored = PrefixIndex(deserializing: i.serialize())
        XCTAssertEqual(restored, i)
        XCTAssertEqual(restored?.count, 0)
    }

    func testDeserializeRejectsTruncatedBlob() {
        var blob = index(["git", "go"]).serialize()
        blob.removeLast()
        XCTAssertNil(PrefixIndex(deserializing: blob))
    }

    func testDeserializeRejectsTrailingBytes() {
        var blob = index(["git"]).serialize()
        blob.append(0x00)
        XCTAssertNil(PrefixIndex(deserializing: blob), "slack after the declared tokens must fail closed")
    }

    func testDeserializeRejectsWrongMagic() {
        var blob = index(["git"]).serialize()
        blob[0] = 0x00
        XCTAssertNil(PrefixIndex(deserializing: blob))
    }

    func testDeserializeRejectsWrongVersion() {
        var blob = index(["git"]).serialize()
        blob[4] = 0x02
        XCTAssertNil(PrefixIndex(deserializing: blob))
    }

    func testDeserializeRejectsEmpty() {
        XCTAssertNil(PrefixIndex(deserializing: []))
    }

    func testDeserializeRejectsNonAscendingTokens() {
        // Hand-build a GPIX blob with tokens out of byte order: the invariant
        // binary search depends on must be enforced on read, not trusted.
        var blob: [UInt8] = Array("GPIX".utf8)
        blob.append(0x01)                                   // version
        appendLE32(&blob, 2)                                // count = 2
        for tok in ["go", "git"] {                          // descending → invalid
            appendLE32(&blob, UInt32(tok.utf8.count))
            blob.append(contentsOf: tok.utf8)
        }
        XCTAssertNil(PrefixIndex(deserializing: blob), "non-ascending tokens break binary search → reject")
    }

    func testDeserializeRejectsDuplicateTokens() {
        var blob: [UInt8] = Array("GPIX".utf8)
        blob.append(0x01)
        appendLE32(&blob, 2)
        for tok in ["git", "git"] {                         // not strictly ascending
            appendLE32(&blob, UInt32(tok.utf8.count))
            blob.append(contentsOf: tok.utf8)
        }
        XCTAssertNil(PrefixIndex(deserializing: blob), "duplicate (non-unique) tokens must fail closed")
    }

    func testDeserializeRejectsHostileTokenLength() {
        // A token length field claiming far more bytes than remain must fail
        // closed, not over-read or allocate ~4GB.
        var blob: [UInt8] = Array("GPIX".utf8)
        blob.append(0x01)
        appendLE32(&blob, 1)                                // count = 1
        appendLE32(&blob, 0xFFFF_FFFF)                      // token len = 4 billion
        blob.append(contentsOf: "git".utf8)                 // but only 3 bytes follow
        XCTAssertNil(PrefixIndex(deserializing: blob))
    }
}
