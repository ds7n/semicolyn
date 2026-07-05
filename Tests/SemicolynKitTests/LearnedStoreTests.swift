// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// LearnedStore — Critical tier. Persists/restores the user's windowed learned
/// vocabulary; fail-soft to empty on first run or corruption. Exercised against
/// real temp directories. See `2026-06-21-predictor-learned-store-design`.
final class LearnedStoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("learnedstore-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// A state with `git` (unigram) and `git → status` (bigram) recorded.
    private func sampleState() -> LearnedState {
        var uni = RollingVocabulary()
        uni.record("git", count: 4)
        var bi = RollingBigramVocabulary()
        bi.record(previous: "git", next: "status", count: 3)
        return LearnedState(unigram: uni, bigram: bi)
    }

    private func uniCount(_ s: LearnedState, _ token: String) -> UInt32? {
        s.unigram.learnedSource(window: .days7).candidates(forPrefix: token)
            .first { $0.token == token }?.count
    }

    func testFirstRunLoadsEmptyState() {
        let state = LearnedStore(directory: dir).load()
        XCTAssertNil(uniCount(state, "git"), "first run must yield an empty unigram store")
        XCTAssertEqual(state.bigram.candidates(after: "git", window: .days7), [],
                       "first run must yield an empty bigram store")
    }

    func testSaveThenLoadRoundTrips() throws {
        let store = LearnedStore(directory: dir)
        try store.save(sampleState())
        let loaded = store.load()
        XCTAssertEqual(uniCount(loaded, "git"), 4)
        XCTAssertEqual(loaded.bigram.candidates(after: "git", window: .days7),
                       [TokenCount(token: "status", count: 3)])
    }

    func testSaveOverwrites() throws {
        let store = LearnedStore(directory: dir)
        try store.save(sampleState())
        var uni = RollingVocabulary()
        uni.record("docker", count: 9)
        try store.save(LearnedState(unigram: uni, bigram: RollingBigramVocabulary()))
        let loaded = store.load()
        XCTAssertEqual(uniCount(loaded, "docker"), 9)
        XCTAssertNil(uniCount(loaded, "git"), "the overwritten save must not retain old state")
    }

    func testSaveCreatesDirectory() throws {
        // dir does not exist yet.
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        try LearnedStore(directory: dir).save(sampleState())
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("learned.sketch").path))
    }

    func testRolloverStateSurvivesRoundTrip() throws {
        // A post-rollover state must restore with its dailies intact so windows
        // and eviction stay correct after load.
        var uni = RollingVocabulary()
        uni.record("deploy", count: 2)
        uni.rollover()
        uni.record("git", count: 5)
        let store = LearnedStore(directory: dir)
        try store.save(LearnedState(unigram: uni, bigram: RollingBigramVocabulary()))
        let loaded = store.load()
        XCTAssertEqual(uniCount(loaded, "deploy"), 2, "sealed daily must survive")
        XCTAssertEqual(uniCount(loaded, "git"), 5, "today must survive")
    }

    func testCorruptFileFallsBackToEmpty() throws {
        let store = LearnedStore(directory: dir)
        try store.save(sampleState())
        let url = dir.appendingPathComponent("learned.sketch")
        var bytes = try Data(contentsOf: url)
        bytes[0] = 0x00   // corrupt the wrapper magic
        try bytes.write(to: url)
        let loaded = store.load()
        XCTAssertNil(uniCount(loaded, "git"),
                     "a corrupt learned file must fail soft to an empty state, not throw")
    }

    func testTruncatedFileFallsBackToEmpty() throws {
        let store = LearnedStore(directory: dir)
        try store.save(sampleState())
        let url = dir.appendingPathComponent("learned.sketch")
        let bytes = try Data(contentsOf: url)
        try bytes.prefix(bytes.count - 12).write(to: url)
        XCTAssertNil(uniCount(store.load(), "git"), "a truncated file must fail soft to empty")
    }

    func testLoadedStateIsMutableAndStillRollsOver() throws {
        // The restored state must be a fully-functional rolling store.
        let store = LearnedStore(directory: dir)
        try store.save(sampleState())
        var loaded = store.load()
        loaded.unigram.record("git", count: 1)   // 4 + 1 in today
        XCTAssertEqual(uniCount(loaded, "git"), 5)
        loaded.unigram.rollover()                  // still works post-load
        XCTAssertEqual(uniCount(loaded, "git"), 5, "rollover must preserve in-window counts")
    }

    // MARK: - Task 6: delete

    func testDeleteThenLoadReturnsEmpty() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("phase4-del-\(UUID().uuidString)")
        let store = LearnedStore(directory: dir)
        var state = LearnedState.empty
        state.unigram.record("persisted", count: 3)
        try store.save(state)
        XCTAssertFalse(store.load().unigram.learnedSource(window: .days30)
            .candidates(forPrefix: "persist").isEmpty)  // precondition: saved
        try store.delete()
        XCTAssertTrue(store.load().unigram.learnedSource(window: .days30)
            .candidates(forPrefix: "persist").isEmpty, "delete removes the persisted store")
    }

    func testDeleteMissingFileDoesNotThrow() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("phase4-nofile-\(UUID().uuidString)")
        XCTAssertNoThrow(try LearnedStore(directory: dir).delete())  // idempotent
    }
}
