// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import NeotildeKit

/// Bloom filter — Critical tier. Verifies the defining no-false-negatives
/// guarantee and fail-closed (de)serialization.
final class BloomFilterTests: XCTestCase {
    func testInsertedTokensAlwaysContained() {
        // No false negatives: every inserted token must report contained.
        var bloom = BloomFilter(bitCount: 1 << 16, hashCount: 7)
        let tokens = ["git", "kubectl", "docker", "ssh", "vim", "grep", "awk"]
        for t in tokens { bloom.insert(t) }
        for t in tokens {
            XCTAssertTrue(bloom.mightContain(t), "inserted token \(t) must be contained")
        }
    }

    func testEmptyFilterContainsNothing() {
        // The safe, non-flaky negative: an empty filter has no bits set.
        let bloom = BloomFilter(bitCount: 1 << 16, hashCount: 7)
        XCTAssertFalse(bloom.mightContain("git"))
        XCTAssertFalse(bloom.mightContain(""))
    }

    func testInsertIsDeterministic() {
        var a = BloomFilter(bitCount: 4096, hashCount: 5)
        var b = BloomFilter(bitCount: 4096, hashCount: 5)
        a.insert("kubectl")
        b.insert("kubectl")
        XCTAssertEqual(a, b, "same insert on same dims must yield identical bits")
    }

    func testSerializationRoundTrip() {
        var bloom = BloomFilter(bitCount: 1 << 16, hashCount: 7)
        bloom.insert("git")
        bloom.insert("docker")
        let blob = bloom.serialize()
        let restored = BloomFilter(deserializing: blob)
        XCTAssertEqual(restored, bloom)
        XCTAssertEqual(restored?.mightContain("git"), true)
        XCTAssertEqual(restored?.mightContain("docker"), true)
    }

    func testDeserializeRejectsTruncatedBlob() {
        var blob = BloomFilter(bitCount: 4096, hashCount: 5).serialize()
        blob.removeLast()
        XCTAssertNil(BloomFilter(deserializing: blob))
    }

    func testDeserializeRejectsWrongMagic() {
        var blob = BloomFilter(bitCount: 4096, hashCount: 5).serialize()
        blob[0] = 0x00
        XCTAssertNil(BloomFilter(deserializing: blob))
    }

    func testDeserializeRejectsWrongVersion() {
        var blob = BloomFilter(bitCount: 4096, hashCount: 5).serialize()
        blob[4] = 0x09
        XCTAssertNil(BloomFilter(deserializing: blob))
    }

    func testDeserializeRejectsEmpty() {
        XCTAssertNil(BloomFilter(deserializing: []))
    }
}
