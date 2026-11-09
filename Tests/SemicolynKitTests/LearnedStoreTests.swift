// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
@testable import SemicolynKit

/// LearnedStore, Critical tier (privacy P-H2). The learned state is sealed with the
/// record key in `learned.sealed`; load is tri-state (found / absent / unreadable);
/// the old plaintext `learned.sketch` (GLRN v1) migrates once. Exercised against
/// real temp directories. See `2026-11-08-predictor-learned-fade-design`.
final class LearnedStoreTests: XCTestCase {
    private var dir: URL!
    private var key: SymmetricKey!

    private var sealedURL: URL { dir.appendingPathComponent("learned.sealed") }
    private var legacyURL: URL { dir.appendingPathComponent("learned.sketch") }

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("learnedstore-\(UUID().uuidString)", isDirectory: true)
        key = SymmetricKey(size: .bits256)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        try? FileManager.default.removeItem(at: dir)
    }

    private func store(_ key: SymmetricKey? = nil) -> LearnedStore {
        LearnedStore(directory: dir, key: key ?? self.key)
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// A state with fractional counts (`git` 1.5 after one halving, `git → status`
    /// 1.5) and a mid-step fade clock.
    private func sampleState() -> LearnedState {
        var uni = LearnedVocabulary()
        uni.record("git", count: 3)
        uni.scale(by: 0.5)
        var bi = LearnedBigramVocabulary()
        bi.record(previous: "git", next: "status", count: 3)
        bi.scale(by: 0.5)
        return LearnedState(unigram: uni, bigram: bi, wordsSinceFade: 437)
    }

    private func found(_ load: LearnedLoad, file: StaticString = #filePath,
                       line: UInt = #line) -> LearnedState? {
        guard case let .found(state) = load else {
            XCTFail("expected .found, got \(load)", file: file, line: line)
            return nil
        }
        return state
    }

    // MARK: - Sealed file

    func testNothingStoredIsAbsent() {
        XCTAssertEqual(store().load(), .absent)
    }

    func testSealedRoundTripEqualsSavedState() throws {
        let state = sampleState()
        XCTAssertEqual(state.unigram.estimate("git"), 1.5)   // precondition: fractional
        try store().save(state)
        XCTAssertEqual(store().load(), .found(state))
        XCTAssertTrue(exists(sealedURL))
        XCTAssertFalse(exists(legacyURL), "nothing writes the plaintext learned.sketch any more")
    }

    func testSaveOverwrites() throws {
        try store().save(sampleState())
        var uni = LearnedVocabulary()
        uni.record("docker", count: 9)
        let second = LearnedState(unigram: uni, bigram: LearnedBigramVocabulary(), wordsSinceFade: 5)
        try store().save(second)
        XCTAssertEqual(store().load(), .found(second))
    }

    func testPlaintextLiteralNotInFile() throws {
        var state = LearnedState.empty
        state.unigram.record("hunter2xyz", count: 2)
        state.bigram.record(previous: "login", next: "hunter2xyz", count: 2)
        try store().save(state)
        let fileBytes = [UInt8](try Data(contentsOf: sealedURL))
        let needle = Array("hunter2xyz".utf8)
        let leaked = fileBytes.count >= needle.count
            && (0...(fileBytes.count - needle.count)).contains { Array(fileBytes[$0..<$0 + needle.count]) == needle }
        XCTAssertFalse(leaked, "the literal must not appear in the sealed file bytes")
        // Control: the state really holds it (so the search above is meaningful).
        XCTAssertEqual(found(store().load())?.unigram.containsLiteral("hunter2xyz"), true)
    }

    func testWrongKeyIsAbsent() throws {
        try store().save(sampleState())
        XCTAssertEqual(store(SymmetricKey(size: .bits256)).load(), .absent)
    }

    func testFlippedByteIsAbsent() throws {
        try store().save(sampleState())
        var bytes = try Data(contentsOf: sealedURL)
        bytes[bytes.count / 2] ^= 0x01
        try bytes.write(to: sealedURL)
        XCTAssertEqual(store().load(), .absent)
    }

    func testTruncatedSealedFileIsAbsent() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: sealedURL)
        XCTAssertEqual(store().load(), .absent)
    }

    // A file that exists but can't be read (a locked device) is unreadable, simulated
    // with a directory where the file should be.
    func testDirectoryAtSealedPathIsUnreadable() throws {
        try FileManager.default.createDirectory(at: sealedURL, withIntermediateDirectories: true)
        XCTAssertEqual(store().load(), .unreadable)
    }

    // MARK: - Malformed sealed plaintext (validly sealed, fails closed)

    /// The GLFD v1 plaintext, hand-built so each field can be broken independently.
    private func plaintext(magic: [UInt8] = Array("GLFD".utf8), version: UInt8 = 1,
                           wordsSinceFade: UInt32 = 437,
                           unigram: [UInt8]? = nil, bigram: [UInt8]? = nil) -> [UInt8] {
        let state = sampleState()
        var out = magic
        out.append(version)
        appendLE32(&out, wordsSinceFade)
        appendSubBlob(&out, unigram ?? state.unigram.serialize())
        appendSubBlob(&out, bigram ?? state.bigram.serialize())
        return out
    }

    private func writeSealed(_ plain: [UInt8]) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let box = try AES.GCM.seal(Data(plain), using: key)
        try XCTUnwrap(box.combined).write(to: sealedURL)
    }

    func testHandBuiltPlaintextLoads() throws {
        // Control for the malformed cases below: the unbroken helper output is valid.
        try writeSealed(plaintext())
        XCTAssertEqual(store().load(), .found(sampleState()))
    }

    func testBadMagicIsAbsent() throws {
        try writeSealed(plaintext(magic: Array("GLRN".utf8)))
        XCTAssertEqual(store().load(), .absent)
    }

    func testUnknownVersionIsAbsent() throws {
        try writeSealed(plaintext(version: 2))
        XCTAssertEqual(store().load(), .absent)
    }

    func testTrailingByteIsAbsent() throws {
        try writeSealed(plaintext() + [0x00])
        XCTAssertEqual(store().load(), .absent)
    }

    func testTruncatedPlaintextIsAbsent() throws {
        try writeSealed(Array(plaintext().dropLast()))
        XCTAssertEqual(store().load(), .absent)
    }

    func testFadeClockAtStepIsAbsent() throws {
        // wordsSinceFade is always below the step size; 999 is the largest legal value.
        try writeSealed(plaintext(wordsSinceFade: 999))
        XCTAssertEqual(found(store().load())?.wordsSinceFade, 999)
        try writeSealed(plaintext(wordsSinceFade: 1000))
        XCTAssertEqual(store().load(), .absent)
    }

    func testMismatchedDimensionsAreAbsent() throws {
        try writeSealed(plaintext(unigram: LearnedVocabulary(depth: 4, width: 1 << 15).serialize()))
        XCTAssertEqual(store().load(), .absent)
        try writeSealed(plaintext(bigram: LearnedBigramVocabulary(depth: 4, width: 1 << 14).serialize()))
        XCTAssertEqual(store().load(), .absent)
    }

    func testSwappedSubBlobsAreAbsent() throws {
        let state = sampleState()
        try writeSealed(plaintext(unigram: state.bigram.serialize(), bigram: state.unigram.serialize()))
        XCTAssertEqual(store().load(), .absent)
    }

    // MARK: - Migration from GLRN v1

    /// A CountMinSketch format-v1 blob (UInt32 cells) with `entries` added.
    private func legacySketch(width: Int, _ entries: [(String, UInt32)] = []) -> [UInt8] {
        var sketch = CountMinSketch(depth: 4, width: width)
        for (token, count) in entries { sketch.add(token, count: Float(count)) }
        let v2 = sketch.serialize()
        var out = Array(v2[0..<13])
        out[4] = 1
        var p = 13
        while p < v2.count {
            let cell = Float(bitPattern: readLE32(v2, p)!)
            appendLE32(&out, UInt32(cell))
            p += 4
        }
        return out
    }

    /// An old `RollingVocabulary` (GRLV v1) blob: `magic | version | index | today |
    /// rolling7 | rolling30 | rolling90 | dailyCount | dailies...`.
    private func legacyRolling(width: Int, literals: [String], today: [(String, UInt32)],
                               rolling7: [(String, UInt32)] = [], rolling30: [(String, UInt32)] = [],
                               rolling90: [(String, UInt32)] = [],
                               dailies: [[(String, UInt32)]] = []) -> [UInt8] {
        var index = PrefixIndex()
        for literal in literals { index.insert(literal) }
        var out = Array("GRLV".utf8)
        out.append(1)
        appendSubBlob(&out, index.serialize())
        appendSubBlob(&out, legacySketch(width: width, today))
        appendSubBlob(&out, legacySketch(width: width, rolling7))
        appendSubBlob(&out, legacySketch(width: width, rolling30))
        appendSubBlob(&out, legacySketch(width: width, rolling90))
        appendLE32(&out, UInt32(dailies.count))
        for daily in dailies { appendSubBlob(&out, legacySketch(width: width, daily)) }
        return out
    }

    /// An old `learned.sketch` (GLRN v1): `"alpha"` x3 in today, `"beta"` x2 in the
    /// rolling windows (and the one daily that composes them), `git → status` x4 in
    /// the bigram's today.
    private func legacyFile() -> [UInt8] {
        let unigram = legacyRolling(width: 1 << 14, literals: ["alpha", "beta"],
                                    today: [("alpha", 3)],
                                    rolling7: [("beta", 2)], rolling30: [("beta", 2)],
                                    rolling90: [("beta", 2)], dailies: [[("beta", 2)]])
        let key = "git\u{1F}status"
        var bigram = Array("GRBG".utf8)
        bigram.append(1)
        bigram += legacyRolling(width: 1 << 16, literals: [key], today: [(key, 4)])
        var out = Array("GLRN".utf8)
        out.append(1)
        appendSubBlob(&out, unigram)
        appendSubBlob(&out, bigram)
        return out
    }

    private func writeLegacy(_ bytes: [UInt8]) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(bytes).write(to: legacyURL)
    }

    func testLegacyParserCollapsesTodayAndRolling90() throws {
        let state = try XCTUnwrap(legacyLearnedState(legacyFile()))
        XCTAssertEqual(state.unigram.estimate("alpha"), 3)
        XCTAssertEqual(state.unigram.estimate("beta"), 2, "rolling7/30 and dailies are not added on top")
        XCTAssertTrue(state.unigram.containsLiteral("alpha"))
        XCTAssertTrue(state.unigram.containsLiteral("beta"))
        XCTAssertEqual(state.bigram.candidates(after: "git"), [TokenCount(token: "status", count: 4)])
        XCTAssertEqual(state.wordsSinceFade, 0)
    }

    func testLegacyParserRejectsMalformed() {
        let good = legacyFile()
        XCTAssertNil(legacyLearnedState([]))
        XCTAssertNil(legacyLearnedState(Array("GLFD".utf8) + Array(good[4...])), "bad magic")
        var v2 = good
        v2[4] = 2
        XCTAssertNil(legacyLearnedState(v2), "unknown version")
        XCTAssertNil(legacyLearnedState(good + [0]), "trailing byte")
        XCTAssertNil(legacyLearnedState(Array(good.dropLast())), "truncated")
    }

    func testLegacyParserRejectsWrongDimensions() {
        // A unigram store at the bigram width cannot become a 4 x 2^14 vocabulary.
        var out = Array("GLRN".utf8)
        out.append(1)
        appendSubBlob(&out, legacyRolling(width: 1 << 15, literals: ["alpha"], today: [("alpha", 1)]))
        var bigram = Array("GRBG".utf8)
        bigram.append(1)
        bigram += legacyRolling(width: 1 << 16, literals: [], today: [])
        appendSubBlob(&out, bigram)
        XCTAssertNil(legacyLearnedState(out))
    }

    func testLegacyParserEnforcesCap() throws {
        let literals = (0..<(LearnedState.literalCap + 1)).map { String(format: "w%05d", $0) }
        var out = Array("GLRN".utf8)
        out.append(1)
        appendSubBlob(&out, legacyRolling(width: 1 << 14, literals: literals, today: [("w00000", 9)]))
        var bigram = Array("GRBG".utf8)
        bigram.append(1)
        bigram += legacyRolling(width: 1 << 16, literals: [], today: [])
        appendSubBlob(&out, bigram)
        let state = try XCTUnwrap(legacyLearnedState(out))
        XCTAssertEqual(state.unigram.literalCount, LearnedState.literalCapTarget)
        XCTAssertTrue(state.unigram.containsLiteral("w00000"), "the highest estimate is kept")
    }

    func testMigrationWritesSealedAndDeletesLegacy() throws {
        try writeLegacy(legacyFile())
        let state = try XCTUnwrap(found(store().load()))
        XCTAssertEqual(state.unigram.estimate("alpha"), 3)
        XCTAssertEqual(state.unigram.estimate("beta"), 2)
        XCTAssertTrue(state.unigram.containsLiteral("alpha"))
        XCTAssertTrue(state.unigram.containsLiteral("beta"))
        XCTAssertFalse(exists(legacyURL), "learned.sketch is deleted after the sealed write")
        XCTAssertTrue(exists(sealedURL))
        // The next load reads the sealed copy.
        XCTAssertEqual(store().load(), .found(state))
    }

    func testMigrationWithUnwritableDirectoryKeepsLegacy() throws {
        try writeLegacy(legacyFile())
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }
        try XCTSkipIf(getuid() == 0, "root ignores directory permissions")

        let state = try XCTUnwrap(found(store().load()))
        XCTAssertEqual(state.unigram.estimate("alpha"), 3)
        XCTAssertTrue(exists(legacyURL), "a failed sealed write keeps the old file for next session")
        XCTAssertFalse(exists(sealedURL))
    }

    func testLegacyUnreadableIsUnreadable() throws {
        try FileManager.default.createDirectory(at: legacyURL, withIntermediateDirectories: true)
        XCTAssertEqual(store().load(), .unreadable)
        XCTAssertFalse(exists(sealedURL), "nothing is written over an unreadable store")
    }

    func testMalformedLegacyIsAbsent() throws {
        try writeLegacy(Array(legacyFile().dropLast()))
        XCTAssertEqual(store().load(), .absent)
        XCTAssertFalse(exists(sealedURL))
    }

    func testSealedFileWinsOverLegacy() throws {
        let state = sampleState()
        try store().save(state)
        try writeLegacy(legacyFile())
        XCTAssertEqual(store().load(), .found(state))
    }

    // MARK: - delete

    func testDeleteRemovesBothFilesAndIsIdempotent() throws {
        try store().save(sampleState())
        try writeLegacy(legacyFile())
        try store().delete()
        XCTAssertFalse(exists(sealedURL))
        XCTAssertFalse(exists(legacyURL))
        XCTAssertEqual(store().load(), .absent)
        XCTAssertNoThrow(try store().delete())   // nothing left: still no error
    }

    func testDeleteRemovesLegacyAlone() throws {
        try writeLegacy(legacyFile())
        try store().delete()
        XCTAssertFalse(exists(legacyURL))
    }

    func testDeleteOnMissingDirectoryDoesNotThrow() {
        XCTAssertNoThrow(try store().delete())
    }
}
