// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// Count-Min Sketch, Critical tier (correctness-critical, and the serialized
/// blob is a synced format). Verifies one-sided error, saturating add, pointwise
/// merge, clamp-at-zero subtract, and fail-closed (de)serialization.
final class CountMinSketchTests: XCTestCase {
    // MARK: estimate / add

    func testEmptySketchEstimatesZero() {
        let cms = CountMinSketch(depth: 4, width: 1024)
        XCTAssertEqual(cms.estimate("git"), 0)
    }

    func testSingleTokenEstimateIsExact() {
        // With only one token added, no foreign collisions inflate it.
        var cms = CountMinSketch(depth: 4, width: 1 << 14)
        for _ in 0..<5 { cms.add("git") }
        XCTAssertEqual(cms.estimate("git"), 5)
    }

    func testAddWithCount() {
        var cms = CountMinSketch(depth: 4, width: 1 << 14)
        cms.add("git", count: 7)
        XCTAssertEqual(cms.estimate("git"), 7)
    }

    func testNeverUnderestimatesAcrossManyTokens() {
        // CMS one-sided error: estimate >= true count even with collisions.
        var cms = CountMinSketch(depth: 4, width: 256)  // small width → real collisions
        for i in 0..<200 { cms.add("token-\(i)") }
        cms.add("target", count: 9)
        XCTAssertGreaterThanOrEqual(cms.estimate("target"), 9)
    }

    func testLargeCountsStayFinite() {
        var cms = CountMinSketch(depth: 4, width: 1 << 14)
        cms.add("x", count: 1e30)
        cms.add("x", count: 1e30)
        let e = cms.estimate("x")
        XCTAssertTrue(e.isFinite, "large counts must not overflow to inf or NaN")
        XCTAssertEqual(e, 2e30, accuracy: 1e24)
    }

    func testNonFiniteOrNegativeCountIgnored() {
        var cms = CountMinSketch(depth: 4, width: 1 << 14)
        cms.add("x", count: 3)
        cms.add("x", count: .nan)
        cms.add("x", count: .infinity)
        cms.add("x", count: -2)
        XCTAssertEqual(cms.estimate("x"), 3)
    }

    // MARK: scale

    func testScaleHalvesEstimate() {
        var cms = CountMinSketch(depth: 4, width: 1 << 14)
        cms.add("a", count: 8)
        cms.scale(by: 0.5)
        XCTAssertEqual(cms.estimate("a"), 4)
    }

    func testScaleToZeroFloor() {
        var cms = CountMinSketch(depth: 4, width: 1 << 14)
        cms.add("a", count: 8)
        cms.scale(by: 0)
        XCTAssertEqual(cms.estimate("a"), 0)
    }

    func testScaleIgnoresNonFiniteOrNegativeFactor() {
        var cms = CountMinSketch(depth: 4, width: 1 << 14)
        cms.add("a", count: 8)
        cms.scale(by: .nan)
        cms.scale(by: .infinity)
        cms.scale(by: -1)
        XCTAssertEqual(cms.estimate("a"), 8)
    }

    // MARK: merge

    func testMergeIsPointwiseSum() {
        var a = CountMinSketch(depth: 4, width: 1 << 14)
        var b = CountMinSketch(depth: 4, width: 1 << 14)
        a.add("x", count: 3)
        b.add("x", count: 5)
        XCTAssertTrue(a.merge(b))
        XCTAssertEqual(a.estimate("x"), 8)
    }

    func testMergeRejectsDimensionMismatch() {
        var a = CountMinSketch(depth: 4, width: 16)
        let b = CountMinSketch(depth: 4, width: 32)
        a.add("x", count: 3)
        XCTAssertFalse(a.merge(b), "merge across differing widths must be refused")
        XCTAssertEqual(a.estimate("x"), 3, "rejected merge must not mutate")
    }

    // MARK: subtract (clamp at zero)

    func testSubtractClampsAtZeroNeverWraps() {
        var a = CountMinSketch(depth: 4, width: 1 << 14)
        var b = CountMinSketch(depth: 4, width: 1 << 14)
        a.add("x", count: 3)
        b.add("x", count: 5)              // subtract more than present
        XCTAssertTrue(a.subtract(b))
        XCTAssertEqual(a.estimate("x"), 0, "underflow must clamp to 0, not wrap to ~4 billion")
    }

    func testSubtractPartial() {
        var a = CountMinSketch(depth: 4, width: 1 << 14)
        var b = CountMinSketch(depth: 4, width: 1 << 14)
        a.add("x", count: 10)
        b.add("x", count: 3)
        XCTAssertTrue(a.subtract(b))
        XCTAssertEqual(a.estimate("x"), 7)
    }

    func testSubtractRejectsDimensionMismatch() {
        var a = CountMinSketch(depth: 4, width: 16)
        let b = CountMinSketch(depth: 2, width: 16)
        a.add("x", count: 4)
        XCTAssertFalse(a.subtract(b))
        XCTAssertEqual(a.estimate("x"), 4)
    }

    // MARK: serialization

    func testSerializationRoundTrip() {
        var cms = CountMinSketch(depth: 4, width: 256)
        cms.add("git", count: 4)
        cms.add("kubectl", count: 2)
        let blob = cms.serialize()
        let restored = CountMinSketch(deserializing: blob)
        XCTAssertEqual(restored, cms)
        XCTAssertEqual(restored?.estimate("git"), 4)
    }

    func testDeserializeRejectsTruncatedBlob() {
        let cms = CountMinSketch(depth: 4, width: 256)
        var blob = cms.serialize()
        blob.removeLast()
        XCTAssertNil(CountMinSketch(deserializing: blob))
    }

    func testDeserializeRejectsWrongMagic() {
        var blob = CountMinSketch(depth: 4, width: 256).serialize()
        blob[0] = 0x00
        XCTAssertNil(CountMinSketch(deserializing: blob))
    }

    func testDeserializeRejectsWrongVersion() {
        var blob = CountMinSketch(depth: 4, width: 256).serialize()
        blob[4] = 0x03
        XCTAssertNil(CountMinSketch(deserializing: blob))
        blob[4] = 0x00
        XCTAssertNil(CountMinSketch(deserializing: blob))
    }

    func testV2RoundTripKeepsFractions() {
        var cms = CountMinSketch(depth: 4, width: 256)
        cms.add("git", count: 2.5)
        let blob = cms.serialize()
        XCTAssertEqual(blob[4], 2, "serialize writes format version 2")
        let restored = CountMinSketch(deserializing: blob)
        XCTAssertEqual(restored, cms)
        XCTAssertEqual(restored?.estimate("git"), 2.5)
    }

    func testV1BlobDecodes() {
        // Hand-built v1: header + UInt32 cells, with "git" x5 added to a 2x8 sketch.
        let idx = StableHash.indices("git", count: 2, modulo: 8)
        var cells = [UInt32](repeating: 0, count: 16)
        for r in 0..<2 { cells[r * 8 + idx[r]] = 5 }
        var blob: [UInt8] = [0x47, 0x43, 0x4d, 0x53, 0x01]
        appendLE32(&blob, 2)
        appendLE32(&blob, 8)
        for c in cells { appendLE32(&blob, c) }
        let cms = CountMinSketch(deserializing: blob)
        XCTAssertEqual(cms?.estimate("git"), 5)
        XCTAssertEqual(cms?.estimate("other-zero-token-xyz") ?? -1, 0, accuracy: 5)
    }

    func testV1TruncatedBlobRejected() {
        var blob: [UInt8] = [0x47, 0x43, 0x4d, 0x53, 0x01]
        appendLE32(&blob, 2)
        appendLE32(&blob, 8)
        for _ in 0..<15 { appendLE32(&blob, 1) }
        XCTAssertNil(CountMinSketch(deserializing: blob))
    }

    func testV2TruncatedBlobRejected() {
        var blob = CountMinSketch(depth: 2, width: 8).serialize()
        blob.removeLast(4)
        XCTAssertNil(CountMinSketch(deserializing: blob))
    }

    func testV2NonFiniteCellRejected() {
        var blob = CountMinSketch(depth: 1, width: 1).serialize()
        let n = blob.count
        let bits = Float.nan.bitPattern
        for i in 0..<4 { blob[n - 4 + i] = UInt8((bits >> (8 * UInt32(i))) & 0xff) }
        XCTAssertNil(CountMinSketch(deserializing: blob))
    }

    func testDeserializeRejectsEmpty() {
        XCTAssertNil(CountMinSketch(deserializing: []))
    }

    func testDeserializeRejectsHostileDimensionOverflow() {
        // magic + version + depth=0xFFFFFFFF + width=0xFFFFFFFF, no cells:
        // depth*width overflows Int → must fail closed, not allocate/crash.
        var blob: [UInt8] = [0x47, 0x43, 0x4d, 0x53, 0x01]
        blob.append(contentsOf: [0xff, 0xff, 0xff, 0xff])
        blob.append(contentsOf: [0xff, 0xff, 0xff, 0xff])
        XCTAssertNil(CountMinSketch(deserializing: blob))
    }
}
