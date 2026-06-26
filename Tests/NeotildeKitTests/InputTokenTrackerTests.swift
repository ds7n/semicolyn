// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import NeotildeKit

final class InputTokenTrackerTests: XCTestCase {
    private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    func testTypingBuildsCurrentToken() {
        var t = InputTokenTracker()
        let committed = t.observe(bytes("clau"))
        XCTAssertTrue(committed.isEmpty)
        XCTAssertEqual(t.current, "clau")
        XCTAssertNil(t.previous)
    }

    func testSpaceCommitsAndShiftsPrevious() {
        var t = InputTokenTracker()
        let committed = t.observe(bytes("git "))
        XCTAssertEqual(committed, [CommittedToken(token: "git", previous: nil)])
        XCTAssertEqual(t.current, "")
        XCTAssertEqual(t.previous, "git")
    }

    func testSecondTokenCarriesPreviousForBigram() {
        var t = InputTokenTracker()
        let committed = t.observe(bytes("git commit"))
        XCTAssertEqual(committed, [CommittedToken(token: "git", previous: nil)])
        XCTAssertEqual(t.current, "commit")
        XCTAssertEqual(t.previous, "git")   // drives suggestions(forPrefix:"commit", after:"git")
    }

    func testMultipleTokensInOneChunk() {
        var t = InputTokenTracker()
        let committed = t.observe(bytes("a b c"))
        XCTAssertEqual(committed, [CommittedToken(token: "a", previous: nil),
                                   CommittedToken(token: "b", previous: "a")])
        XCTAssertEqual(t.current, "c")
        XCTAssertEqual(t.previous, "b")
    }

    func testEnterCommitsAndResetsLine() {
        var t = InputTokenTracker()
        _ = t.observe(bytes("git commit"))
        let committed = t.observe([0x0d])
        XCTAssertEqual(committed, [CommittedToken(token: "commit", previous: "git")])
        XCTAssertEqual(t.current, "")
        XCTAssertNil(t.previous)            // new line: no preceding token
    }

    func testBackspacePopsCurrent() {
        var t = InputTokenTracker()
        _ = t.observe(bytes("claude"))
        _ = t.observe([0x7f])
        XCTAssertEqual(t.current, "claud")
    }

    func testTabClearsCurrentWithoutCommitting() {
        var t = InputTokenTracker()
        _ = t.observe(bytes("co"))
        let committed = t.observe([0x09])
        XCTAssertTrue(committed.isEmpty)    // remote completion, not a learned token
        XCTAssertEqual(t.current, "")
    }

    func testControlByteResetsLineContext() {
        var t = InputTokenTracker()
        _ = t.observe(bytes("git commit"))
        _ = t.observe([0x03])              // Ctrl+C
        XCTAssertEqual(t.current, "")
        XCTAssertNil(t.previous)
    }

    func testChipsDropExactCurrentAndEmpties() {
        XCTAssertEqual(predictorChips(current: "clau", suggestions: ["claude", "clang"]),
                       ["claude", "clang"])
        XCTAssertEqual(predictorChips(current: "claude", suggestions: ["claude", "clangd"]),
                       ["clangd"])          // exact current dropped
        XCTAssertEqual(predictorChips(current: "x", suggestions: []), [])
    }
}
