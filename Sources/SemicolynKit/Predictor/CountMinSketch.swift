// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// A Count-Min Sketch: per-token frequency in bounded memory with one-sided
/// error. `estimate` never *under*-counts (until a `subtract` or `scale` below
/// 1); collisions can only inflate. `depth` rows × `width` cells, `Float`
/// counters so the whole sketch can fade multiplicatively (`scale(by:)`).
/// Backs the predictor's unigram/bigram frequency tables. See
/// `2026-06-21-predictor-core-sketches-design`.
public struct CountMinSketch: Equatable, Sendable {
    public let depth: Int
    public let width: Int
    private var cells: [Float]

    private static let magic: [UInt8] = [0x47, 0x43, 0x4d, 0x53]  // "GCMS"
    /// v2: Float32 bit-pattern cells. v1 (UInt32 cells) is still decoded.
    private static let formatVersion: UInt8 = 2
    private static let headerSize = 13  // magic(4) + version(1) + depth(4) + width(4)

    /// A zeroed sketch with `depth` hash rows and `width` cells per row.
    public init(depth: Int, width: Int) {
        precondition(depth > 0 && width > 0, "CMS dimensions must be positive")
        self.depth = depth
        self.width = width
        self.cells = [Float](repeating: 0, count: depth * width)
    }

    /// Add `count` occurrences of `token`. Each row's chosen cell increments,
    /// clamped at `Float.greatestFiniteMagnitude` (never becomes infinite). A
    /// non-finite or negative `count` is ignored.
    public mutating func add(_ token: String, count: Float = 1) {
        guard count.isFinite, count >= 0 else { return }
        let idx = StableHash.indices(token, count: depth, modulo: width)
        for r in 0..<depth {
            let p = r * width + idx[r]
            cells[p] = Self.clampedSum(cells[p], count)
        }
    }

    /// Estimated frequency of `token`, the minimum across its rows. Never below
    /// the true count (one-sided error), unless a `subtract` or `scale` has
    /// reduced a cell.
    public func estimate(_ token: String) -> Float {
        let idx = StableHash.indices(token, count: depth, modulo: width)
        var m = Float.greatestFiniteMagnitude
        for r in 0..<depth {
            m = Swift.min(m, cells[r * width + idx[r]])
        }
        return m
    }

    /// Multiply every cell by `factor` (the fade step). A non-finite or negative
    /// `factor` is ignored so a hostile value cannot poison the cells.
    public mutating func scale(by factor: Float) {
        guard factor.isFinite, factor >= 0 else { return }
        for i in 0..<cells.count { cells[i] *= factor }
    }

    /// Pointwise add `other` into self (sketch union). Returns false and does
    /// nothing if dimensions differ. Clamped at the largest finite value.
    @discardableResult
    public mutating func merge(_ other: CountMinSketch) -> Bool {
        guard depth == other.depth, width == other.width else { return false }
        for i in 0..<cells.count {
            cells[i] = Self.clampedSum(cells[i], other.cells[i])
        }
        return true
    }

    /// Pointwise subtract `other` from self (eviction), clamping each cell at
    /// zero. Returns false and does nothing if dimensions differ. A subtracted
    /// sketch may then under-estimate; that is the spec's accepted, tolerable
    /// noise for rollover eviction.
    @discardableResult
    public mutating func subtract(_ other: CountMinSketch) -> Bool {
        guard depth == other.depth, width == other.width else { return false }
        for i in 0..<cells.count {
            cells[i] = cells[i] > other.cells[i] ? cells[i] - other.cells[i] : 0
        }
        return true
    }

    private static func clampedSum(_ a: Float, _ b: Float) -> Float {
        let sum = a + b
        return sum.isFinite ? sum : Float.greatestFiniteMagnitude
    }

    /// Serialize to the self-describing little-endian blob format (version 2).
    public func serialize() -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(Self.headerSize + cells.count * 4)
        out.append(contentsOf: Self.magic)
        out.append(Self.formatVersion)
        appendLE32(&out, UInt32(depth))
        appendLE32(&out, UInt32(width))
        for c in cells { appendLE32(&out, c.bitPattern) }
        return out
    }

    /// Reconstruct from a blob. Fails closed (`nil`) on wrong magic, unknown
    /// version (accepts 1 and 2), dimension overflow, or wrong length, a corrupt or hostile
    /// (synced) blob never yields a half-populated sketch.
    public init?(deserializing bytes: [UInt8]) {
        guard bytes.count >= Self.headerSize,
              Array(bytes[0..<4]) == Self.magic,
              bytes[4] == 1 || bytes[4] == Self.formatVersion,
              let d = readLE32(bytes, 5), let w = readLE32(bytes, 9) else { return nil }
        let depth = Int(d), width = Int(w)
        guard depth > 0, width > 0 else { return nil }
        // Guard against a hostile blob declaring huge dimensions that overflow.
        let (cellCount, ov1) = depth.multipliedReportingOverflow(by: width)
        guard !ov1 else { return nil }
        let (cellBytes, ov2) = cellCount.multipliedReportingOverflow(by: 4)
        guard !ov2 else { return nil }
        let (expected, ov3) = cellBytes.addingReportingOverflow(Self.headerSize)
        guard !ov3, bytes.count == expected else { return nil }

        let isV1 = bytes[4] == 1
        var cells: [Float] = []
        cells.reserveCapacity(cellCount)
        var p = Self.headerSize
        for _ in 0..<cellCount {
            guard let v = readLE32(bytes, p) else { return nil }
            let cell = isV1 ? Float(v) : Float(bitPattern: v)
            // A non-finite or negative cell can only come from a corrupt blob.
            guard cell.isFinite, cell >= 0 else { return nil }
            cells.append(cell)
            p += 4
        }
        self.depth = depth
        self.width = width
        self.cells = cells
    }
}
