// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class SuggestionRequestTests: XCTestCase {
    // EP: current non-empty, completions present -> completeWord (today's path)
    func testCompleteWordWhenCompletionsExist() {
        let r = suggestionRequest(current: "comm", previous: nil, precedingToken: nil,
                                  currentWordCompletionsWereEmpty: false,
                                  currentIsTerminalWord: false,
                                  lineOptedOut: false, minPrefix: 2)
        XCTAssertEqual(r, .completeWord(prefix: "comm", previous: nil))
    }

    // EP: current empty, previous usable -> nextWord(after: previous)  [Trigger A]
    func testNextWordOnSpaceCommit() {
        let r = suggestionRequest(current: "", previous: "git", precedingToken: "git",
                                  currentWordCompletionsWereEmpty: false,
                                  currentIsTerminalWord: false,
                                  lineOptedOut: false, minPrefix: 2)
        XCTAssertEqual(r, .nextWord(after: "git"))
    }

    // EP: current empty, no usable previous -> none (start of line)
    func testNoneAtLineStart() {
        let r = suggestionRequest(current: "", previous: nil, precedingToken: nil,
                                  currentWordCompletionsWereEmpty: false,
                                  currentIsTerminalWord: false,
                                  lineOptedOut: false, minPrefix: 2)
        XCTAssertEqual(r, .none)
    }
    func testNoneWhenPreviousEmptyString() {
        let r = suggestionRequest(current: "", previous: "", precedingToken: nil,
                                  currentWordCompletionsWereEmpty: false,
                                  currentIsTerminalWord: false,
                                  lineOptedOut: false, minPrefix: 2)
        XCTAssertEqual(r, .none)
    }

    // EP: current non-empty, completions empty, count >= minPrefix, terminal word -> nextWord(after: current)  [Trigger B]
    func testNextWordWhenCurrentWordDry() {
        let r = suggestionRequest(current: "whoami", previous: nil, precedingToken: nil,
                                  currentWordCompletionsWereEmpty: true,
                                  currentIsTerminalWord: true,
                                  lineOptedOut: false, minPrefix: 2)
        XCTAssertEqual(r, .nextWord(after: "whoami"))
    }

    // BVA on minPrefix: count == minPrefix fires; count == minPrefix-1 does not
    func testTriggerBAtMinPrefixBoundary() {
        let atFloor = suggestionRequest(current: "ab", previous: nil, precedingToken: nil,
                                        currentWordCompletionsWereEmpty: true,
                                        currentIsTerminalWord: true,
                                        lineOptedOut: false, minPrefix: 2)
        XCTAssertEqual(atFloor, .nextWord(after: "ab"))
        let belowFloor = suggestionRequest(current: "a", previous: nil, precedingToken: nil,
                                           currentWordCompletionsWereEmpty: true,
                                           currentIsTerminalWord: true,
                                           lineOptedOut: false, minPrefix: 2)
        XCTAssertEqual(belowFloor, .none)
    }

    // Adversarial: Trigger B suppressed on an opted-out line (leading-space line)
    func testTriggerBSuppressedWhenOptedOut() {
        let r = suggestionRequest(current: "whoami", previous: nil, precedingToken: nil,
                                  currentWordCompletionsWereEmpty: true,
                                  currentIsTerminalWord: true,
                                  lineOptedOut: true, minPrefix: 2)
        XCTAssertEqual(r, .none)
    }

    // Adversarial: Trigger B suppressed when current is an L4b secret VALUE token.
    // `--password SECRET` -> precedingToken "--password" marks "SECRET" as a secret value.
    func testTriggerBSuppressedWhenCurrentIsSecretValue() {
        let r = suggestionRequest(current: "hunter2", previous: nil, precedingToken: "--password",
                                  currentWordCompletionsWereEmpty: true,
                                  currentIsTerminalWord: true,
                                  lineOptedOut: false, minPrefix: 2)
        XCTAssertEqual(r, .none)
    }

    // Trigger A is NOT gated by minPrefix (bigram path exempt): empty current, short previous still fires.
    func testTriggerANotGatedByMinPrefix() {
        let r = suggestionRequest(current: "", previous: "a", precedingToken: "a",
                                  currentWordCompletionsWereEmpty: false,
                                  currentIsTerminalWord: false,
                                  lineOptedOut: false, minPrefix: 2)
        XCTAssertEqual(r, .nextWord(after: "a"))
    }

    // Fix: dry completions but current is NOT a terminal word (still-typing partial) -> none.
    func testTriggerBSuppressedWhenNotTerminalWord() {
        let r = suggestionRequest(current: "is", previous: nil, precedingToken: nil,
                                  currentWordCompletionsWereEmpty: true,
                                  currentIsTerminalWord: false,
                                  lineOptedOut: false, minPrefix: 2)
        XCTAssertEqual(r, .none)
    }

    // Terminal word + dry -> nextWord fires (the finished-word case still works).
    func testTriggerBFiresWhenTerminalWord() {
        let r = suggestionRequest(current: "whoami", previous: nil, precedingToken: nil,
                                  currentWordCompletionsWereEmpty: true,
                                  currentIsTerminalWord: true,
                                  lineOptedOut: false, minPrefix: 2)
        XCTAssertEqual(r, .nextWord(after: "whoami"))
    }

    // Terminal word but opted out -> none (secret/opt-out guard still wins over terminal).
    func testTriggerBTerminalButOptedOut() {
        let r = suggestionRequest(current: "whoami", previous: nil, precedingToken: nil,
                                  currentWordCompletionsWereEmpty: true,
                                  currentIsTerminalWord: true,
                                  lineOptedOut: true, minPrefix: 2)
        XCTAssertEqual(r, .none)
    }

    // Trigger A (current empty) is unaffected by the new param (pass either value).
    func testTriggerAUnaffectedByTerminalParam() {
        let r = suggestionRequest(current: "", previous: "git", precedingToken: "git",
                                  currentWordCompletionsWereEmpty: false,
                                  currentIsTerminalWord: false,
                                  lineOptedOut: false, minPrefix: 2)
        XCTAssertEqual(r, .nextWord(after: "git"))
    }
}
