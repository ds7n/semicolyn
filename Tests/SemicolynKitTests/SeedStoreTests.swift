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
}
