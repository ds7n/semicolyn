// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SeedKit

struct ScriptedPredictor: ReplayPredictor {
    var table: [String: [String]]
    var commits: [String] = []
    mutating func suggestions(line: String) -> [String] { table[line] ?? [] }
    mutating func commit(line: String) { commits.append(line) }
}

final class ReplayHarnessTests: XCTestCase {
    func testHitsJumpAndConsumeSpace() {
        var p = ScriptedPredictor(table: ["g": ["git"], "git ": ["status"]])
        let r = replay(lines: ["git status"], predictor: &p, config: .init())
        XCTAssertEqual(r.keystrokes, 10)
        XCTAssertEqual(r.keystrokesSaved, 7)       // "it " (3-1) + "status" (6-1)
        XCTAssertEqual(r.hitsBySlot, [2, 0, 0, 0, 0])
        XCTAssertEqual(r.lookups, 1)
        XCTAssertEqual(r.emptyLookups, 0)
    }

    func testEmptyLookupsCounted() {
        var p = ScriptedPredictor(table: [:])
        let r = replay(lines: ["ab"], predictor: &p, config: .init())
        XCTAssertEqual(r.lookups, 2)
        XCTAssertEqual(r.emptyLookups, 2)
        XCTAssertEqual(r.zeroRate, 1.0)
        XCTAssertEqual(r.keystrokesSaved, 0)
    }

    func testSlotBoundary() {
        var p = ScriptedPredictor(table: ["a": ["x1", "x2", "x3", "x4", "x5", "ab"]])
        XCTAssertEqual(replay(lines: ["ab"], predictor: &p, config: .init(visibleSlots: 5)).keystrokesSaved, 0)
        var q = ScriptedPredictor(table: ["a": ["x1", "x2", "x3", "x4", "ab"]])
        XCTAssertEqual(replay(lines: ["ab"], predictor: &q, config: .init(visibleSlots: 5)).hitsBySlot[4], 1)
    }

    func testPunctuationAfterWordCostsAKeystroke() {
        var p = ScriptedPredictor(table: ["m": ["me"]])
        XCTAssertEqual(replay(lines: ["me, ok"], predictor: &p, config: .init()).keystrokesSaved, -1)
    }

    func testSlashWordGetsNoSpace() {
        // "src/" ends in "/": no chip space, so the line's own space is still typed.
        var p = ScriptedPredictor(table: ["cd s": ["src/"]])
        XCTAssertEqual(replay(lines: ["cd src/ x"], predictor: &p, config: .init()).keystrokesSaved, 2)
    }

    func testCommitOnlyWhenLearning() {
        var p = ScriptedPredictor(table: [:])
        _ = replay(lines: ["a", "b"], predictor: &p, config: .init(learn: false))
        XCTAssertEqual(p.commits, [])
        _ = replay(lines: ["a", "b"], predictor: &p, config: .init(learn: true))
        XCTAssertEqual(p.commits, ["a", "b"])
    }

    func testReportEqualityIgnoresLatencies() {
        var a = ReplayReport(keystrokes: 1, keystrokesSaved: 0, lookups: 0, emptyLookups: 0,
                             hitsBySlot: [0], latenciesMs: [1.0])
        var b = a
        b.latenciesMs = [9.0, 3.0]
        XCTAssertEqual(a, b)
        b.keystrokesSaved = 1
        XCTAssertNotEqual(a, b)
        a.keystrokesSaved = 1
        XCTAssertEqual(a, b)
    }

    func testDerivedMetrics() {
        let r = ReplayReport(keystrokes: 200, keystrokesSaved: 50, lookups: 4, emptyLookups: 1,
                             hitsBySlot: [0], latenciesMs: (1...20).map(Double.init))
        XCTAssertEqual(r.savedPer100, 25.0)
        XCTAssertEqual(r.zeroRate, 0.25)
        XCTAssertEqual(r.p95LatencyMs, 19.0)
        let empty = ReplayReport(keystrokes: 0, keystrokesSaved: 0, lookups: 0, emptyLookups: 0,
                                 hitsBySlot: [], latenciesMs: [])
        XCTAssertEqual(empty.savedPer100, 0)
        XCTAssertEqual(empty.zeroRate, 0)
        XCTAssertEqual(empty.p95LatencyMs, 0)
    }
}

final class LegacyReplayTests: XCTestCase {
    func testNoSeedYieldsNoSuggestionsAndCommitLearnsWords() {
        var p = LegacyReplay(cliSeed: nil, proseSeed: nil)
        XCTAssertEqual(p.suggestions(line: "gi"), [])
        // The graduation tier defers learning until a token recurs, so commit repeatedly.
        for _ in 0..<6 { p.commit(line: "gitfoo status") }
        XCTAssertTrue(p.suggestions(line: "gitf").contains("gitfoo"))
    }
}
