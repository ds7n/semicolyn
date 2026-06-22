// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// A sorted, de-duplicated set of token strings with binary-search prefix
/// lookup. Supplies the *candidate* tokens a frequency sketch can't enumerate
/// (a `CountMinSketch` is lossy). Case-sensitive — terminal tokens are. See
/// `2026-06-21-predictor-prefix-ranking-design`.
///
/// Ordering, equality, and prefix matching are all by **UTF-8 bytes**, not by
/// `Swift.String`'s Unicode-canonical comparison. This is deliberate: with byte
/// ordering, "all tokens having a byte prefix form a contiguous sorted run" is a
/// theorem (byte lexicographic order ↔ byte prefix), so the binary-search +
/// forward-scan below is provably complete. Relying on `String.<` vs grapheme
/// `hasPrefix` instead would be only "correct in practice" — they can disagree on
/// combining marks. Byte semantics are also the right model for terminal tokens
/// (the user types bytes, and distinct byte sequences are distinct tokens even
/// when canonically equivalent).
public struct PrefixIndex: Equatable, Sendable {
    private var tokens: [String]   // sorted ascending by UTF-8 bytes, unique by bytes

    public init() { tokens = [] }

    /// Number of distinct tokens held.
    public var count: Int { tokens.count }

    /// Insert `token`, preserving the sorted-unique invariant. A repeat (same
    /// bytes) is a no-op.
    public mutating func insert(_ token: String) {
        let i = lowerBound(token)
        if i < tokens.count && tokens[i].utf8.elementsEqual(token.utf8) { return }
        tokens.insert(token, at: i)
    }

    /// Every token having `prefix` (by bytes), in sorted order. Empty prefix
    /// matches all. O(log n + k) for k matches: binary-search the lower bound,
    /// then scan the contiguous matching run.
    public func matching(prefix: String) -> [String] {
        if prefix.isEmpty { return tokens }
        let prefixBytes = Array(prefix.utf8)
        var result: [String] = []
        var i = lowerBound(prefix)
        while i < tokens.count && tokens[i].utf8.starts(with: prefixBytes) {
            result.append(tokens[i])
            i += 1
        }
        return result
    }

    /// First index whose token is `>= key` in UTF-8 byte order.
    private func lowerBound(_ key: String) -> Int {
        let keyBytes = Array(key.utf8)
        var lo = 0, hi = tokens.count
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            if tokens[mid].utf8.lexicographicallyPrecedes(keyBytes) { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    // MARK: - Serialization

    private static let magic: [UInt8] = [0x47, 0x50, 0x49, 0x58]  // "GPIX"
    private static let formatVersion: UInt8 = 1
    private static let headerSize = 9  // magic(4) + version(1) + count(4)

    /// Serialize to the self-describing little-endian blob format:
    /// `magic | version | count | [len | UTF-8 bytes]×count`. Tokens are emitted
    /// in their stored ascending-byte order.
    public func serialize() -> [UInt8] {
        var out: [UInt8] = []
        out.append(contentsOf: Self.magic)
        out.append(Self.formatVersion)
        appendLE32(&out, UInt32(tokens.count))
        for token in tokens {
            let bytes = Array(token.utf8)
            appendLE32(&out, UInt32(bytes.count))
            out.append(contentsOf: bytes)
        }
        return out
    }

    /// Reconstruct from a blob. Fails closed (`nil`) on wrong magic, unknown
    /// version, a length field that overruns the buffer, trailing slack, or tokens
    /// that are not strictly ascending by UTF-8 bytes — the latter would silently
    /// break the binary search, so a corrupt/hostile blob is rejected rather than
    /// trusted. Never pre-allocates from the untrusted count.
    public init?(deserializing bytes: [UInt8]) {
        guard bytes.count >= Self.headerSize,
              Array(bytes[0..<4]) == Self.magic,
              bytes[4] == Self.formatVersion,
              let count = readLE32(bytes, 5) else { return nil }

        var result: [String] = []
        var p = Self.headerSize
        var previousBytes: [UInt8]? = nil
        for _ in 0..<count {
            guard let tokenBytes = readLengthPrefixed(bytes, &p) else { return nil }
            // Reject invalid UTF-8 outright — lossy decoding would desync the
            // stored string's bytes from the order validated here. `String(bytes:
            // encoding:)` returns nil on invalid UTF-8 (strict, like the stdlib
            // `String(validating:as:)`) and, unlike it, is available on iOS 17 / macOS 14.
            guard let token = String(bytes: tokenBytes, encoding: .utf8) else { return nil }
            // Enforce the strictly-ascending, unique invariant on read.
            if let prev = previousBytes, !prev.lexicographicallyPrecedes(tokenBytes) { return nil }
            result.append(token)
            previousBytes = tokenBytes
        }
        guard p == bytes.count else { return nil }  // no trailing slack
        tokens = result
    }
}
