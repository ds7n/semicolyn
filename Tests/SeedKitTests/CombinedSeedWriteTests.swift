// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SeedKit
import SemicolynKit

final class CombinedSeedWriteTests: XCTestCase {
    // The build tool must assemble the two blobs into a seed_pinned-format blob that
    // the app's BundledSeed(combinedBlob:) parses back to the same content.
    func testCombinedBlobFromBuilderBlobsParsesBack() {
        let combined = combinedSeedBlob(version: 1, unigram: [10, 20], bigram: [30])
        let parsed = BundledSeed(combinedBlob: combined)
        XCTAssertEqual(parsed?.version, 1)
        XCTAssertEqual(parsed?.unigramBlob, [10, 20])
        XCTAssertEqual(parsed?.bigramBlob, [30])
    }
}
