// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// A Bloom filter: approximate set membership with **no false negatives** (a
/// `false` from `mightContain` is definitive; a `true` may be a false positive).
/// `bitCount` bits, `hashCount` hash functions. Backs the predictor's
/// "have we seen this token?" check and output-token harvesting. See
/// `2026-06-21-predictor-core-sketches-design`.
public struct BloomFilter: Equatable, Sendable {
    public let bitCount: Int
    public let hashCount: Int
    private var bits: [UInt8]

    private static let magic: [UInt8] = [0x47, 0x42, 0x4c, 0x4d]  // "GBLM"
    private static let formatVersion: UInt8 = 1
    private static let headerSize = 13  // magic(4) + version(1) + bitCount(4) + hashCount(4)

    /// An empty filter with `bitCount` bits and `hashCount` hash functions.
    public init(bitCount: Int, hashCount: Int) {
        precondition(bitCount > 0 && hashCount > 0, "Bloom dimensions must be positive")
        self.bitCount = bitCount
        self.hashCount = hashCount
        self.bits = [UInt8](repeating: 0, count: (bitCount + 7) / 8)
    }

    /// Record `token` as present by setting its `hashCount` bits.
    public mutating func insert(_ token: String) {
        for idx in StableHash.indices(token, count: hashCount, modulo: bitCount) {
            bits[idx >> 3] |= UInt8(1 << (idx & 7))
        }
    }

    /// True iff every one of `token`'s bits is set. `false` is definitive (no
    /// false negatives); `true` may be a false positive.
    public func mightContain(_ token: String) -> Bool {
        for idx in StableHash.indices(token, count: hashCount, modulo: bitCount) {
            if bits[idx >> 3] & UInt8(1 << (idx & 7)) == 0 { return false }
        }
        return true
    }

    /// Serialize to the self-describing little-endian blob format.
    public func serialize() -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(Self.headerSize + bits.count)
        out.append(contentsOf: Self.magic)
        out.append(Self.formatVersion)
        appendLE32(&out, UInt32(bitCount))
        appendLE32(&out, UInt32(hashCount))
        out.append(contentsOf: bits)
        return out
    }

    /// Reconstruct from a blob. Fails closed (`nil`) on wrong magic, unknown
    /// version, non-positive dimensions, or wrong length.
    public init?(deserializing bytes: [UInt8]) {
        guard bytes.count >= Self.headerSize,
              Array(bytes[0..<4]) == Self.magic,
              bytes[4] == Self.formatVersion,
              let m = readLE32(bytes, 5), let k = readLE32(bytes, 9) else { return nil }
        let bitCount = Int(m), hashCount = Int(k)
        guard bitCount > 0, hashCount > 0 else { return nil }
        // Checked all the way through, mirroring the CMS deserialize guards, so a
        // hostile blob can never overflow the byte-count math (defensive — on a
        // 64-bit target a UInt32 bitCount can't actually overflow Int).
        let (plus7, ov1) = bitCount.addingReportingOverflow(7)
        guard !ov1 else { return nil }
        let byteCount = plus7 / 8
        let (expected, ov2) = byteCount.addingReportingOverflow(Self.headerSize)
        guard !ov2, bytes.count == expected else { return nil }
        self.bitCount = bitCount
        self.hashCount = hashCount
        self.bits = Array(bytes[Self.headerSize..<bytes.count])
    }
}
