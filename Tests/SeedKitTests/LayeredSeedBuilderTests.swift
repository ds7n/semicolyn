// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SeedKit
@testable import SemicolynKit

final class LayeredSeedBuilderTests: XCTestCase {
    private func unigram(_ blob: [UInt8]) -> Vocabulary { Vocabulary(deserializing: blob)! }

    // Normalization: a tiny layer and a huge layer with equal WEIGHT contribute
    // equally to a shared token, not in proportion to raw size.
    func testNormalizationEqualizesLayerMass() {
        var b = LayeredSeedBuilder()
        // layer A: "alpha" once; layer B: "alpha" 1000x. Equal weight -> equal contribution.
        let cfg = LayerConfig(weight: 1.0, bigramCapPerLayer: .max, bigramFloor: 1)
        b.addLayer("small", config: cfg, sentences: [["alpha"]])
        b.addLayer("big", config: cfg, sentences: Array(repeating: ["alpha"], count: 1000))
        let v = unigram(b.blobs().unigram)
        // Both layers normalized to the same mass, so "alpha" gets ~2*C, and a token
        // present in only one layer ("beta") would get ~1*C. Assert "alpha" count is
        // close to 2x a single-layer token.
        var b2 = LayeredSeedBuilder()
        b2.addLayer("solo", config: cfg, sentences: [["beta"]])
        let solo = unigram(b2.blobs().unigram).candidates(forPrefix: "beta").first!.count
        let both = v.candidates(forPrefix: "alpha").first!.count
        // both should be ~2x solo (within CountMinSketch tolerance): assert >= 1.8x.
        XCTAssertGreaterThanOrEqual(Double(both), 1.8 * Double(solo))
    }

    // Weight multiplier: a 2x-weighted layer contributes ~2x an equal 1x layer.
    func testWeightMultiplierScalesContribution() {
        var heavy = LayeredSeedBuilder()
        heavy.addLayer("h", config: LayerConfig(weight: 2.0, bigramCapPerLayer: .max, bigramFloor: 1),
                       sentences: [["gamma"]])
        var light = LayeredSeedBuilder()
        light.addLayer("l", config: LayerConfig(weight: 1.0, bigramCapPerLayer: .max, bigramFloor: 1),
                       sentences: [["gamma"]])
        let h = unigram(heavy.blobs().unigram).candidates(forPrefix: "gamma").first!.count
        let l = unigram(light.blobs().unigram).candidates(forPrefix: "gamma").first!.count
        XCTAssertGreaterThanOrEqual(Double(h), 1.8 * Double(l))
    }

    // Rare-bigram floor: a bigram seen once with floor=2 is dropped.
    func testRareBigramFloorDropsSingletons() {
        var b = LayeredSeedBuilder()
        // "must not" appears once; floor 2 -> dropped from the bigram store.
        b.addLayer("t", config: LayerConfig(weight: 1.0, bigramCapPerLayer: .max, bigramFloor: 2),
                   sentences: [["must", "not"]])
        let bi = BigramVocabulary(deserializing: b.blobs().bigram)!
        XCTAssertTrue(bi.nextSource(after: "must").candidates(forPrefix: "not").isEmpty)
    }

    // Bigram cap: a boilerplate bigram repeated 10000x is capped so it cannot dominate.
    func testBigramCapLimitsBoilerplate() {
        var b = LayeredSeedBuilder()
        let sentences = Array(repeating: ["see", "also"], count: 10_000)
        b.addLayer("t", config: LayerConfig(weight: 1.0, bigramCapPerLayer: 100, bigramFloor: 1),
                   sentences: sentences)
        let bi = BigramVocabulary(deserializing: b.blobs().bigram)!
        let c = bi.nextSource(after: "see").candidates(forPrefix: "also").first!.count
        XCTAssertLessThanOrEqual(c, 100)
    }
}
