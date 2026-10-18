// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// HarvestBuffer: Core tier. Coalesces remote output for the screen-word harvest
/// behind a byte cap (newest bytes win) with at most one harvest in flight, and
/// flags a drop so the engine resets its harvest context across the gap.
final class HarvestBufferTests: XCTestCase {
    /// `n` bytes counting 0, 1, 2 ... (mod 251), so every retained window is
    /// distinguishable by its exact first and last byte.
    private func ramp(_ n: Int) -> [UInt8] { (0..<n).map { UInt8($0 % 251) } }

    // MARK: cap boundary (default 8192)

    func testDefaultCapacityIs8192() {
        XCTAssertEqual(HarvestBuffer.defaultCapacity, 8192)
        XCTAssertEqual(HarvestBuffer().capacity, 8192)
    }

    func testBelowCapKeepsEverythingWithoutDrop() {
        var b = HarvestBuffer()
        b.append(ramp(8191))
        XCTAssertEqual(b.takeIfIdle(), HarvestChunk(bytes: ramp(8191), droppedBefore: false))
    }

    func testAtCapKeepsEverythingWithoutDrop() {
        var b = HarvestBuffer()
        b.append(ramp(8192))
        XCTAssertEqual(b.takeIfIdle(), HarvestChunk(bytes: ramp(8192), droppedBefore: false))
    }

    func testOverCapByOneDropsTheOldestByte() {
        var b = HarvestBuffer()
        b.append(ramp(8193))
        XCTAssertEqual(b.takeIfIdle(), HarvestChunk(bytes: Array(ramp(8193).dropFirst()), droppedBefore: true))
    }

    func testCapAppliesAcrossAppends() {
        var b = HarvestBuffer()
        b.append(ramp(8000))
        b.append(ramp(193))                       // 8193 total: the first byte goes
        XCTAssertEqual(b.takeIfIdle(), HarvestChunk(bytes: Array(ramp(8000).dropFirst()) + ramp(193),
                                                    droppedBefore: true))
    }

    func testOneHugeAppendKeepsItsNewestCapBytes() {
        var b = HarvestBuffer(capacity: 4)
        b.append(Array("ab".utf8))
        b.append(Array("cdefgh".utf8))
        XCTAssertEqual(b.takeIfIdle(), HarvestChunk(bytes: Array("efgh".utf8), droppedBefore: true))
    }

    // MARK: drop flag

    func testDropFlagClearsAfterTake() {
        var b = HarvestBuffer(capacity: 4)
        b.append(Array("abcdef".utf8))
        XCTAssertEqual(b.takeIfIdle()?.droppedBefore, true)
        b.finish()
        b.append(Array("xy".utf8))
        XCTAssertEqual(b.takeIfIdle(), HarvestChunk(bytes: Array("xy".utf8), droppedBefore: false))
    }

    func testDropFlagSurvivesFurtherAppendsUntilTaken() {
        var b = HarvestBuffer(capacity: 4)
        b.append(Array("abcde".utf8))             // drop
        _ = b.takeIfIdle()                        // in flight
        b.append(Array("123456".utf8))            // drop while in flight
        b.append(Array("7".utf8))                 // no new drop, but the earlier one stands
        b.finish()
        XCTAssertEqual(b.takeIfIdle(), HarvestChunk(bytes: Array("4567".utf8), droppedBefore: true))
    }

    // MARK: at most one in flight

    func testTakeWhileInFlightReturnsNilAndKeepsBytes() {
        var b = HarvestBuffer()
        b.append(Array("one ".utf8))
        XCTAssertEqual(b.takeIfIdle(), HarvestChunk(bytes: Array("one ".utf8), droppedBefore: false))
        XCTAssertTrue(b.inFlight)
        b.append(Array("two ".utf8))
        b.append(Array("three ".utf8))
        XCTAssertNil(b.takeIfIdle())
        b.finish()
        XCTAssertFalse(b.inFlight)
        XCTAssertEqual(b.takeIfIdle(), HarvestChunk(bytes: Array("two three ".utf8), droppedBefore: false))
    }

    func testTakeWithNothingPendingReturnsNilAndStaysIdle() {
        var b = HarvestBuffer()
        XCTAssertNil(b.takeIfIdle())
        XCTAssertFalse(b.inFlight)
        b.append([])
        XCTAssertNil(b.takeIfIdle())
        XCTAssertFalse(b.inFlight)
    }

    func testResetDropsBytesAndInFlight() {
        var b = HarvestBuffer(capacity: 4)
        b.append(Array("abcdef".utf8))
        _ = b.takeIfIdle()
        b.append(Array("zz".utf8))
        b.reset()
        XCTAssertFalse(b.inFlight)
        XCTAssertNil(b.takeIfIdle())
        b.append(Array("q".utf8))
        XCTAssertEqual(b.takeIfIdle(), HarvestChunk(bytes: Array("q".utf8), droppedBefore: false))
    }

    // MARK: no token spans a drop (engine)

    private func engine() -> PredictorEngine {
        PredictorEngine(learned: .empty, english: nil, commands: nil, filter: .init())
    }

    private func texts(_ e: PredictorEngine, _ line: String) -> [String] {
        e.suggestions(line: line, lineOptedOut: false).map(\.text)
    }

    /// The cap cuts `longword.log` mid-word: the retained text starts `rd.log`, and
    /// that cut fragment is not harvested; the whole words after it are.
    func testCutFragmentAtTheStartIsNotHarvested() {
        var b = HarvestBuffer(capacity: 16)
        b.append(Array("ignored.txt ".utf8))
        b.append(Array("longword.log next.txt\n".utf8))
        let chunk = b.takeIfIdle()
        XCTAssertEqual(chunk, HarvestChunk(bytes: Array("rd.log next.txt\n".utf8), droppedBefore: true))
        var e = engine()
        if let chunk { e.harvest(chunk) }
        XCTAssertEqual(texts(e, "rd"), [])
        XCTAssertEqual(texts(e, "ign"), [])
        XCTAssertEqual(texts(e, "next"), ["next.txt"])
    }

    /// A partial token carried from the previous harvest must not join the first
    /// bytes after a drop (`par` + `tial.log` is not one word).
    func testCarriedPartialDoesNotJoinAcrossADrop() {
        var e = engine()
        e.harvest(output: "keep.txt par")
        e.harvest(HarvestChunk(bytes: Array("tial.log done.txt\n".utf8), droppedBefore: true))
        XCTAssertEqual(texts(e, "par"), [])
        XCTAssertEqual(texts(e, "tial"), [])
        XCTAssertEqual(texts(e, "done"), ["done.txt"])
        XCTAssertEqual(texts(e, "keep"), ["keep.txt"])
    }

    /// Control: without a drop the carried partial does join the next chunk.
    func testCarriedPartialJoinsWithoutADrop() {
        var e = engine()
        e.harvest(output: "keep.txt par")
        e.harvest(HarvestChunk(bytes: Array("tial.log done.txt\n".utf8), droppedBefore: false))
        XCTAssertEqual(texts(e, "par"), ["partial.log"])
        XCTAssertEqual(texts(e, "done"), ["done.txt"])
    }

    /// A drop that lands inside an escape sequence must not leak its tail as a word
    /// (`[38;5;1mred` cut to `5;1mredword`): the cut fragment is skipped.
    func testDropInsideEscapeSequenceDoesNotLeakItsTail() {
        var e = engine()
        e.harvest(HarvestChunk(bytes: Array("5;1mredword.txt\u{1b}[0m clean.log\n".utf8), droppedBefore: true))
        XCTAssertEqual(texts(e, "5"), [])
        XCTAssertEqual(texts(e, "red"), [])
        XCTAssertEqual(texts(e, "clean"), ["clean.log"])
    }
}
