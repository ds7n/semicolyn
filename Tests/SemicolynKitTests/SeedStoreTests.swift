// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// SeedStore — Critical tier. Installs the bundled seed on first launch / version
/// upgrade and loads it back fail-soft. Persists to disk, so exercised against
/// real temp directories. See `2026-06-21-predictor-seed-runtime-load-design`.
final class SeedStoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("seedstore-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// A bundled seed whose bigram has `git → status` and unigram has `git`. Built
    /// from SemicolynKit types directly so these tests don't depend on SeedKit tooling.
    private func bundled(version: Int) -> BundledSeed {
        seed(version: version, command: "git", next: "status")
    }

    private func seed(version: Int, command: String, next: String) -> BundledSeed {
        var uni = Vocabulary(depth: 4, width: 1 << 14)
        uni.record(command)
        var bi = BigramVocabulary()
        bi.record(previous: command, next: next)
        return BundledSeed(version: version, unigramBlob: uni.serialize(), bigramBlob: bi.serialize())
    }

    func testFirstLaunchInstalls() throws {
        let store = SeedStore(directory: dir)
        let installed = try store.installIfNeeded(bundled(version: 1))
        XCTAssertTrue(installed, "first launch must install")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("seed_pinned.sketch").path))
    }

    func testSecondLaunchSameVersionIsNoOp() throws {
        let store = SeedStore(directory: dir)
        _ = try store.installIfNeeded(bundled(version: 1))
        let again = try store.installIfNeeded(bundled(version: 1))
        XCTAssertFalse(again, "same version must not reinstall")
    }

    func testNewerVersionReinstalls() throws {
        let store = SeedStore(directory: dir)
        _ = try store.installIfNeeded(bundled(version: 1))
        let upgraded = try store.installIfNeeded(bundled(version: 2))
        XCTAssertTrue(upgraded, "a newer bundled version must replace the pinned seed")
    }

    func testOlderVersionDoesNotDowngrade() throws {
        let store = SeedStore(directory: dir)
        _ = try store.installIfNeeded(bundled(version: 5))
        let downgrade = try store.installIfNeeded(bundled(version: 3))
        XCTAssertFalse(downgrade, "an older bundled version must be ignored")
    }

    func testLoadAfterInstallRoundTripsQueries() throws {
        let store = SeedStore(directory: dir)
        _ = try store.installIfNeeded(bundled(version: 1))
        let seed = store.loadSeed()
        XCTAssertNotNil(seed)
        XCTAssertEqual(seed?.bigram.candidates(after: "git").map { $0.token }, ["status"])
        XCTAssertEqual(seed?.unigram.candidates(forPrefix: "git"),
                       [TokenCount(token: "git", count: 1)])
    }

    func testNewerVersionContentReplacesOld() throws {
        // v1 has git→status; v2 has docker→run. After upgrade, the loaded seed is v2.
        let store = SeedStore(directory: dir)
        _ = try store.installIfNeeded(bundled(version: 1))
        _ = try store.installIfNeeded(seed(version: 2, command: "docker", next: "run"))
        let seed = store.loadSeed()
        XCTAssertEqual(seed?.bigram.candidates(after: "docker").map { $0.token }, ["run"])
        XCTAssertEqual(seed?.bigram.candidates(after: "git"), [],
                       "the replaced seed must no longer carry v1 content")
    }

    func testLoadWithNoSeedReturnsNil() {
        XCTAssertNil(SeedStore(directory: dir).loadSeed(),
                     "no installed seed must load as nil, not throw")
    }

    func testLoadWithCorruptFileReturnsNil() throws {
        let store = SeedStore(directory: dir)
        _ = try store.installIfNeeded(bundled(version: 1))
        // Corrupt the pinned file's magic.
        let url = dir.appendingPathComponent("seed_pinned.sketch")
        var bytes = try Data(contentsOf: url)
        bytes[0] = 0x00
        try bytes.write(to: url)
        XCTAssertNil(store.loadSeed(), "a corrupt pinned file must fail soft to nil")
    }

    func testTruncatedFileFailsSoftAndReinstalls() throws {
        let store = SeedStore(directory: dir)
        _ = try store.installIfNeeded(bundled(version: 1))
        // Truncate the pinned file into the bigram sub-blob region.
        let url = dir.appendingPathComponent("seed_pinned.sketch")
        let bytes = try Data(contentsOf: url)
        try bytes.prefix(bytes.count - 10).write(to: url)
        XCTAssertNil(store.loadSeed(), "a truncated pinned file must fail soft to nil")
        XCTAssertTrue(try store.installIfNeeded(bundled(version: 1)),
                      "a corrupt file (no readable version) must be treated as not-installed")
    }

    func testSeedPlugsIntoSeededSuggester() throws {
        // The capstone: an installed seed drives suggestions for a user with no
        // history of their own.
        let store = SeedStore(directory: dir)
        _ = try store.installIfNeeded(bundled(version: 1))
        let seed = try XCTUnwrap(store.loadSeed())
        let user = BigramVocabulary()
        let s = SeededSuggester(learned: user.nextSource(after: "git"),
                                seed: seed.bigram.nextSource(after: "git"))
        XCTAssertEqual(s.suggestions(forPrefix: ""), ["status"])
    }

    // Combined-blob codec: BundledSeed.combinedBlob() <-> BundledSeed(combinedBlob:).
    // This is the seam the app-edge install and seedbuild both use; a drift here
    // silently breaks seed install (device issue #3's exact failure).
    func testCombinedBlobRoundTrips() {
        let seed = BundledSeed(version: 7, unigramBlob: [1, 2, 3, 4], bigramBlob: [9, 8])
        let blob = seed.combinedBlob()
        let parsed = BundledSeed(combinedBlob: blob)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.version, 7)
        XCTAssertEqual(parsed?.unigramBlob, [1, 2, 3, 4])
        XCTAssertEqual(parsed?.bigramBlob, [9, 8])
    }

    func testCombinedBlobRoundTripsEmptyBlobs() {
        let seed = BundledSeed(version: 1, unigramBlob: [], bigramBlob: [])
        let parsed = BundledSeed(combinedBlob: seed.combinedBlob())
        XCTAssertEqual(parsed?.version, 1)
        XCTAssertEqual(parsed?.unigramBlob, [])
        XCTAssertEqual(parsed?.bigramBlob, [])
    }

    func testParseRejectsTruncatedHeader() {
        XCTAssertNil(BundledSeed(combinedBlob: [0x47, 0x53]))   // < headerSize (9)
    }

    func testParseRejectsWrongMagic() {
        var blob = BundledSeed(version: 1, unigramBlob: [1], bigramBlob: [2]).combinedBlob()
        blob[0] = 0x00                                          // corrupt "GSED"
        XCTAssertNil(BundledSeed(combinedBlob: blob))
    }

    func testParseRejectsWrongFormatVersion() {
        var blob = BundledSeed(version: 1, unigramBlob: [1], bigramBlob: [2]).combinedBlob()
        blob[4] = 0x02                                          // formatVersion must be 1
        XCTAssertNil(BundledSeed(combinedBlob: blob))
    }

    func testParseRejectsTrailingSlack() {
        var blob = BundledSeed(version: 1, unigramBlob: [1], bigramBlob: [2]).combinedBlob()
        blob.append(0xFF)                                       // extra byte past the bigram
        XCTAssertNil(BundledSeed(combinedBlob: blob))
    }

    func testParseRejectsTruncatedBody() {
        let blob = BundledSeed(version: 1, unigramBlob: [1, 2, 3], bigramBlob: [4]).combinedBlob()
        XCTAssertNil(BundledSeed(combinedBlob: Array(blob.dropLast())))   // last body byte missing
    }
}
