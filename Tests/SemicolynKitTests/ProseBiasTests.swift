// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class ProseBiasTests: XCTestCase {
    // Blind prior: all signals nil -> CLI-lean 0.15
    func testAllNilIsBlindCliPrior() {
        XCTAssertEqual(proseBias(PredictionContext()), 0.15, accuracy: 1e-9)
    }

    // Process is the strong signal.
    func testProseProcessRaisesBias() {
        XCTAssertEqual(proseBias(PredictionContext(foregroundProcess: "claude")),
                       0.85, accuracy: 1e-9)   // 0.5 + 0.35
    }
    func testCliProcessLowersBias() {
        XCTAssertEqual(proseBias(PredictionContext(foregroundProcess: "zsh")),
                       0.15, accuracy: 1e-9)   // 0.5 - 0.35
    }
    func testUnknownProcessStaysNeutral() {
        XCTAssertEqual(proseBias(PredictionContext(foregroundProcess: "weirdtool")),
                       0.5, accuracy: 1e-9)
    }

    // Alt-screen modifies the process vote, not independent.
    func testAltPlusVimIsConfidentProse() {
        XCTAssertEqual(proseBias(PredictionContext(foregroundProcess: "vim",
                                                   isAlternateScreen: true)),
                       1.0, accuracy: 1e-9)   // 0.5 + 0.35 + 0.15 clamped to 1.0
    }
    func testAltDoesNotRescueCliProcess() {
        // zsh on alt screen is unusual; cli vote wins, alt adds nothing.
        XCTAssertEqual(proseBias(PredictionContext(foregroundProcess: "zsh",
                                                   isAlternateScreen: true)),
                       0.15, accuracy: 1e-9)
    }

    // Line-shape: gated on >= 2 words AND first word not a known binary.
    func testSentenceShapedLineNudgesProse() {
        // "how do i" -> 3 words, "how" is not a binary -> +0.15 on top of neutral 0.5
        XCTAssertEqual(proseBias(PredictionContext(line: "how do i")),
                       0.65, accuracy: 1e-9)
    }
    func testSingleWordLineDoesNotNudge() {   // BVA: 1 word (below the >=2 gate)
        XCTAssertEqual(proseBias(PredictionContext(line: "how")),
                       0.5, accuracy: 1e-9)   // a signal is present (line) so prior is 0.5, no nudge
    }
    func testCommandLineDoesNotNudge() {
        // first word "git" is a known binary -> no prose nudge even with 2 words
        XCTAssertEqual(proseBias(PredictionContext(line: "git commit")),
                       0.5, accuracy: 1e-9)
    }

    func testClassifyProcessBasename() {
        XCTAssertEqual(classifyProcess("/usr/bin/python3"), .prose)
        XCTAssertEqual(classifyProcess("ZSH"), .cli)          // case-insensitive
        XCTAssertEqual(classifyProcess("cargo"), .unknown)
        XCTAssertEqual(classifyProcess(nil), .unknown)
    }

    // Clamp: never escape [0,1].
    func testBiasClamped() {
        let b = proseBias(PredictionContext(foregroundProcess: "claude",
                                            isAlternateScreen: true, line: "please explain this"))
        XCTAssertGreaterThanOrEqual(b, 0.0)
        XCTAssertLessThanOrEqual(b, 1.0)
    }
}
