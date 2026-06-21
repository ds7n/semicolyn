// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// A Count-Min Sketch: per-token frequency in bounded memory with one-sided
/// error. `estimate` never *under*-counts (until a `subtract`); collisions can
/// only inflate. `depth` rows × `width` cells, `UInt32` saturating counters.
/// Backs the predictor's unigram/bigram frequency tables. See
/// `2026-06-21-predictor-core-sketches-design`.
public struct CountMinSketch: Equatable, Sendable {
    public let depth: Int
    public let width: Int
    private var cells: [UInt32]

    private static let magic: [UInt8] = [0x47, 0x43, 0x4d, 0x53]  // "GCMS"
    private static let formatVersion: UInt8 = 1
    private static let headerSize = 13  // magic(4) + version(1) + depth(4) + width(4)

    /// A zeroed sketch with `depth` hash rows and `width` cells per row.
    public init(depth: Int, width: Int) {
        precondition(depth > 0 && width > 0, "CMS dimensions must be positive")
        self.depth = depth
        self.width = width
        self.cells = [UInt32](repeating: 0, count: depth * width)
    }

    /// Add `count` occurrences of `token`. Each row's chosen cell increments,
    /// saturating at `UInt32.max` (never wraps).
    public mutating func add(_ token: String, count: UInt32 = 1) {
        let idx = StableHash.indices(token, count: depth, modulo: width)
        for r in 0..<depth {
            let p = r * width + idx[r]
            let (sum, overflow) = cells[p].addingReportingOverflow(count)
            cells[p] = overflow ? .max : sum
        }
    }

    /// Estimated frequency of `token` — the minimum across its rows. Never below
    /// the true count (one-sided error), unless a `subtract` has clamped a cell.
    public func estimate(_ token: String) -> UInt32 {
        let idx = StableHash.indices(token, count: depth, modulo: width)
        var m = UInt32.max
        for r in 0..<depth {
            m = Swift.min(m, cells[r * width + idx[r]])
        }
        return m
    }

    /// Pointwise add `other` into self (sketch union). Returns false and does
    /// nothing if dimensions differ. Saturating.
    @discardableResult
    public mutating func merge(_ other: CountMinSketch) -> Bool {
        guard depth == other.depth, width == other.width else { return false }
        for i in 0..<cells.count {
            let (sum, overflow) = cells[i].addingReportingOverflow(other.cells[i])
            cells[i] = overflow ? .max : sum
        }
        return true
    }

    /// Pointwise subtract `other` from self (eviction), clamping each cell at
    /// zero — never underflows/wraps. Returns false and does nothing if
    /// dimensions differ. A subtracted sketch may then under-estimate; that is
    /// the spec's accepted, tolerable noise for rollover eviction.
    @discardableResult
    public mutating func subtract(_ other: CountMinSketch) -> Bool {
        guard depth == other.depth, width == other.width else { return false }
        for i in 0..<cells.count {
            cells[i] = cells[i] > other.cells[i] ? cells[i] - other.cells[i] : 0
        }
        return true
    }

    /// Serialize to the self-describing little-endian blob format.
    public func serialize() -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(Self.headerSize + cells.count * 4)
        out.append(contentsOf: Self.magic)
        out.append(Self.formatVersion)
        appendLE32(&out, UInt32(depth))
        appendLE32(&out, UInt32(width))
        for c in cells { appendLE32(&out, c) }
        return out
    }

    /// Reconstruct from a blob. Fails closed (`nil`) on wrong magic, unknown
    /// version, dimension overflow, or wrong length — a corrupt or hostile
    /// (synced) blob never yields a half-populated sketch.
    public init?(deserializing bytes: [UInt8]) {
        guard bytes.count >= Self.headerSize,
              Array(bytes[0..<4]) == Self.magic,
              bytes[4] == Self.formatVersion,
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

        var cells: [UInt32] = []
        cells.reserveCapacity(cellCount)
        var p = Self.headerSize
        for _ in 0..<cellCount {
            guard let v = readLE32(bytes, p) else { return nil }
            cells.append(v)
            p += 4
        }
        self.depth = depth
        self.width = width
        self.cells = cells
    }
}
