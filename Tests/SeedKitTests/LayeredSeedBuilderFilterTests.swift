// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SeedKit
@testable import SemicolynKit

final class LayeredSeedBuilderFilterTests: XCTestCase {
    func testFilterDropsBlocklistedUnigramAndItsBigrams() {
        let filter = TokenFilter(patterns: [.blocklist(["badword"])])
        var b = LayeredSeedBuilder(filter: filter)
        b.addLayer("t", config: LayerConfig(weight: 1.0, bigramCapPerLayer: .max, bigramFloor: 1),
                   sentences: [["please", "badword", "now"], ["clean", "words"]])
        let uni = Vocabulary(deserializing: b.blobs().unigram)!
        // "badword" absent; clean tokens present.
        XCTAssertTrue(uni.candidates(forPrefix: "badword").isEmpty)
        XCTAssertFalse(uni.candidates(forPrefix: "clean").isEmpty)
        // bigram please->badword and badword->now both dropped; clean->words kept.
        let bi = BigramVocabulary(deserializing: b.blobs().bigram)!
        XCTAssertTrue(bi.nextSource(after: "please").candidates(forPrefix: "badword").isEmpty)
        XCTAssertTrue(bi.nextSource(after: "badword").candidates(forPrefix: "now").isEmpty)
        XCTAssertFalse(bi.nextSource(after: "clean").candidates(forPrefix: "words").isEmpty)
    }
}
