// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import SemicolynKit

/// Per-layer tuning for `LayeredSeedBuilder`.
public struct LayerConfig: Sendable {
    /// Multiplier applied after normalization (up-weight technical/prompt layers).
    public var weight: Double
    /// Max normalized-weighted contribution any single bigram may add from this layer
    /// (blunts boilerplate like "see also" / "must not").
    public var bigramCapPerLayer: UInt32
    /// Drop layer bigrams whose RAW count is below this (noise + reconstruction margin).
    public var bigramFloor: UInt32

    public init(weight: Double, bigramCapPerLayer: UInt32, bigramFloor: UInt32) {
        self.weight = weight
        self.bigramCapPerLayer = bigramCapPerLayer
        self.bigramFloor = bigramFloor
    }
}

/// Blends several prose corpus layers into one seed sketch: each layer's raw
/// unigram/bigram tallies are normalized to a common mass (so a large corpus
/// doesn't dominate purely by size), scaled by the layer's `weight`, floored
/// and capped for bigram hygiene, then summed pointwise into a shared
/// `Vocabulary`/`BigramVocabulary` pair. See `2026-08-11-context-aware-prediction-plan-B-corpus`.
public struct LayeredSeedBuilder {
    private struct Layer {
        let config: LayerConfig
        var uni: [String: UInt64] = [:]
        var bi: [String: [String: UInt64]] = [:]
    }

    private var layers: [Layer] = []

    /// Common per-layer unigram/bigram mass after normalization (before weight).
    /// `record(_:count:)` takes the scaled count directly (no per-occurrence
    /// loop), so there is no loop-iteration bound to enforce here.
    private let commonMass: Double = 1_000_000

    public init() {}

    /// Fold one layer's sentences in: each token is a raw unigram occurrence,
    /// each adjacent `(previous, next)` pair a raw bigram occurrence. `key`
    /// currently only documents provenance (no per-layer storage keying is
    /// needed since layers are combined in `blobs()`).
    public mutating func addLayer(_ key: String, config: LayerConfig, sentences: [[String]]) {
        var layer = Layer(config: config)
        for sentence in sentences {
            for token in sentence { layer.uni[token, default: 0] += 1 }
            guard sentence.count >= 2 else { continue }
            for i in 1..<sentence.count {
                layer.bi[sentence[i - 1], default: [:]][sentence[i], default: 0] += 1
            }
        }
        layers.append(layer)
    }

    /// Normalize, weight, floor/cap, and sum every added layer into the seed
    /// blob format: the unigram `Vocabulary` and the next-token `BigramVocabulary`,
    /// each in its self-describing fail-closed serialization.
    public func blobs() -> (unigram: [UInt8], bigram: [UInt8]) {
        var unigrams = Vocabulary(depth: 4, width: 1 << 14)
        var bigrams = BigramVocabulary(depth: 4, width: 1 << 16)

        for layer in layers {
            let uniTotal = Double(layer.uni.values.reduce(0, +))
            if uniTotal > 0 {
                let uniScale = (commonMass / uniTotal) * layer.config.weight
                for (token, raw) in layer.uni {
                    let count = normalizedCount(raw: raw, scale: uniScale)
                    guard count > 0 else { continue }
                    unigrams.record(token, count: count)
                }
            }

            let biTotal = Double(layer.bi.values.flatMap(\.values).reduce(0, +))
            guard biTotal > 0 else { continue }
            let biScale = (commonMass / biTotal) * layer.config.weight
            for (previous, nexts) in layer.bi {
                for (next, raw) in nexts {
                    guard raw >= UInt64(layer.config.bigramFloor) else { continue }  // floor on RAW count
                    var count = normalizedCount(raw: raw, scale: biScale)
                    count = min(count, layer.config.bigramCapPerLayer)  // per-layer cap
                    guard count > 0 else { continue }
                    bigrams.record(previous: previous, next: next, count: count)
                }
            }
        }
        return (unigram: unigrams.serialize(), bigram: bigrams.serialize())
    }

    /// Scale a raw layer count and clamp it into `UInt32` range, rounding to
    /// the nearest integer count.
    private func normalizedCount(raw: UInt64, scale: Double) -> UInt32 {
        let scaled = (Double(raw) * scale).rounded()
        guard scaled > 0 else { return 0 }
        guard scaled < Double(UInt32.max) else { return .max }
        return UInt32(scaled)
    }
}
