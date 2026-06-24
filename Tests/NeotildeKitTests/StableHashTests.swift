// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import NeotildeKit

/// Stable hashing is a cross-device contract (sketches sync and merge only if
/// the same token hashes identically everywhere). These tests pin the canonical
/// FNV-1a vectors so the frozen format cannot drift silently, and verify the
/// double-hashing index derivation.
final class StableHashTests: XCTestCase {
    private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    // MARK: FNV-1a known-answer (canonical 64-bit vectors)

    func testFnv1aEmptyIsOffsetBasis() {
        XCTAssertEqual(StableHash.fnv1a64(bytes(""), basis: StableHash.basisA),
                       0xcbf2_9ce4_8422_2325)
    }

    func testFnv1aKnownVectorA() {
        XCTAssertEqual(StableHash.fnv1a64(bytes("a"), basis: StableHash.basisA),
                       0xaf63_dc4c_8601_ec8c)
    }

    func testFnv1aKnownVectorFoobar() {
        XCTAssertEqual(StableHash.fnv1a64(bytes("foobar"), basis: StableHash.basisA),
                       0x8594_4171_f739_67e8)
    }

    // MARK: indices

    func testIndicesDeterministicAcrossCalls() {
        let a = StableHash.indices("kubectl", count: 4, modulo: 1024)
        let b = StableHash.indices("kubectl", count: 4, modulo: 1024)
        XCTAssertEqual(a, b)
    }

    func testIndicesCountAndRange() {
        let idx = StableHash.indices("git", count: 7, modulo: 257)
        XCTAssertEqual(idx.count, 7)
        XCTAssertTrue(idx.allSatisfy { $0 >= 0 && $0 < 257 })
    }

    func testDifferentTokensDifferentHashes() {
        // Not strictly guaranteed, but a collision here would signal a broken
        // hash; the two base hashes must differ for distinct inputs.
        XCTAssertNotEqual(StableHash.fnv1a64(bytes("git"), basis: StableHash.basisA),
                          StableHash.fnv1a64(bytes("kubectl"), basis: StableHash.basisA))
    }
}
