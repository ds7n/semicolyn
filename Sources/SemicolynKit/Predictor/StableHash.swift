// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Deterministic, process-independent hashing for the predictor's sketches.
///
/// **Why not `Swift.Hasher`:** it is randomly seeded per process, so the same
/// token would hash differently across launches and devices — which would
/// corrupt every cross-device sketch merge (sketches sync via CloudKit). This
/// uses a frozen FNV-1a instead; the sketch serialization format carries a
/// version byte so any future change to this hashing is an explicit, detectable
/// format bump rather than a silent divergence.
enum StableHash {
    /// Canonical 64-bit FNV-1a offset basis — the standard starting value.
    static let basisA: UInt64 = 0xcbf2_9ce4_8422_2325
    /// A second basis (the FNV prime, reused as a seed) to decorrelate the two
    /// base hashes used for double hashing.
    static let basisB: UInt64 = 0x0000_0100_0000_01b3

    private static let fnvPrime: UInt64 = 0x0000_0100_0000_01b3

    /// 64-bit FNV-1a over `bytes`, starting from `basis`. Wrapping arithmetic.
    static func fnv1a64<S: Sequence>(_ bytes: S, basis: UInt64) -> UInt64
    where S.Element == UInt8 {
        var h = basis
        for b in bytes {
            h ^= UInt64(b)
            h = h &* fnvPrime
        }
        return h
    }

    /// `count` indices in `[0, modulo)` for `token`, via Kirsch–Mitzenmacher
    /// double hashing: `idx(i) = (h1 + i*h2) mod modulo`. One pair of full
    /// hashes synthesizes any number of indices. `modulo` must be positive.
    static func indices(_ token: String, count: Int, modulo: Int) -> [Int] {
        precondition(modulo > 0, "modulo must be positive")
        let utf8 = Array(token.utf8)
        let h1 = fnv1a64(utf8, basis: basisA)
        let h2 = fnv1a64(utf8, basis: basisB)
        let m = UInt64(modulo)
        var out: [Int] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            let combined = h1 &+ UInt64(i) &* h2
            out.append(Int(combined % m))
        }
        return out
    }
}

// MARK: - Little-endian serialization helpers (shared by the sketches)

/// Append `value` as 4 little-endian bytes.
func appendLE32(_ out: inout [UInt8], _ value: UInt32) {
    out.append(UInt8(value & 0xff))
    out.append(UInt8((value >> 8) & 0xff))
    out.append(UInt8((value >> 16) & 0xff))
    out.append(UInt8((value >> 24) & 0xff))
}

/// Read 4 little-endian bytes at `offset` as a `UInt32`, or nil if out of range.
func readLE32(_ bytes: [UInt8], _ offset: Int) -> UInt32? {
    guard offset >= 0, offset + 4 <= bytes.count else { return nil }
    return UInt32(bytes[offset])
        | (UInt32(bytes[offset + 1]) << 8)
        | (UInt32(bytes[offset + 2]) << 16)
        | (UInt32(bytes[offset + 3]) << 24)
}

/// Read a length-prefixed chunk (`LE32 length | that many bytes`) starting at
/// `offset`, advancing `offset` past the chunk on success. Returns `nil` — and
/// leaves `offset` unspecified — when the length field is missing or runs past
/// the buffer. The single bounds-checked "read a sized sub-blob" primitive the
/// fail-closed deserializers share, so the overrun guard lives in one place.
/// `Int(len)` is safe on the 64-bit-only targets: `len ≤ UInt32.max` and
/// `offset ≤ bytes.count`, so `start + Int(len)` cannot overflow `Int`.
func readLengthPrefixed(_ bytes: [UInt8], _ offset: inout Int) -> [UInt8]? {
    guard let len = readLE32(bytes, offset) else { return nil }
    let start = offset + 4
    let end = start + Int(len)
    guard end <= bytes.count else { return nil }
    offset = end
    return Array(bytes[start..<end])
}
