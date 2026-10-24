// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// D-6: a private ("Don't learn from my typing") engine still suggests from the
/// shipped dictionaries but learns nothing from typing or screen output.
final class PredictorPrivateModeTests: XCTestCase {
    private func dictionary() throws -> WordDictionary {
        try WordDictionary(
            entries: [.init(text: "kubernetes", score: 200), .init(text: "kettle", score: 100)],
            successors: [:])
    }

    private func texts(_ e: PredictorEngine, _ line: String) -> [String] {
        e.suggestions(line: line, lineOptedOut: false).map(\.text)
    }

    func testPrivateEngineStillSuggestsFromDictionary() throws {
        let e = PredictorEngine(learned: .empty, english: try dictionary(), commands: nil, learns: false)
        XCTAssertEqual(texts(e, "ku"), ["kubernetes"])
        XCTAssertEqual(texts(e, "ke"), ["kettle"])
    }

    func testPrivateEngineRecordsNothing() throws {
        var e = PredictorEngine(learned: .empty, english: try dictionary(), commands: nil, learns: false)
        for _ in 0..<5 {
            e.record("zebrafish")
            e.record("status", after: "git", accepted: true)
        }
        XCTAssertEqual(e.state, .empty, "a private session must leave the learned store unchanged")
        XCTAssertEqual(texts(e, "zeb"), [])
    }

    func testPrivateEngineHarvestsNothing() throws {
        var e = PredictorEngine(learned: .empty, english: nil, commands: nil, learns: false)
        e.harvest(output: "deploy.yaml build.log\n")
        XCTAssertEqual(texts(e, "dep"), [])
        XCTAssertEqual(texts(e, "build"), [])
    }

    func testPrivateEngineLeavesSeededStateUnchanged() {
        // Seed a learning engine, snapshot its state, then build a private engine from it.
        var seed = PredictorEngine(learned: .empty, english: nil, commands: nil)
        for _ in 0..<4 { seed.record("claude", accepted: true) }
        let before = seed.state
        XCTAssertNotEqual(before, .empty, "precondition: the seed learned something")

        var e = PredictorEngine(learned: before, english: nil, commands: nil, learns: false)
        for _ in 0..<4 { e.record("clasp", accepted: true) }
        XCTAssertEqual(e.state, before)
    }

    /// Control: the same calls on a learning engine DO change state, so the
    /// assertions above are not vacuous.
    func testLearningEngineDoesLearnTheSameInput() {
        var e = PredictorEngine(learned: .empty, english: nil, commands: nil)
        for _ in 0..<5 { e.record("zebrafish") }
        e.harvest(output: "deploy.yaml\n")
        XCTAssertNotEqual(e.state, .empty)
        XCTAssertEqual(texts(e, "zeb"), ["zebrafish"])
        XCTAssertEqual(texts(e, "dep"), ["deploy.yaml"])
        XCTAssertTrue(e.learns)
    }
}
