// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

import XCTest

@testable import SemicolynKit

final class LineContextTests: XCTestCase {
    let tools: Set<String> = ["git", "ls", "make", "grep", "cd"]
    func ctx(_ l: String) -> LineContext { lineContext(line: l, isKnownTool: { self.tools.contains($0) }) }

    func testSegments() {
        XCTAssertEqual(
            commandSegments(of: "git status | grep foo; ls -l"),
            [
                CommandSegment(words: ["git", "status"], afterPipe: false),
                CommandSegment(words: ["grep", "foo"], afterPipe: true),
                CommandSegment(words: ["ls", "-l"], afterPipe: false),
            ])
        XCTAssertEqual(commandSegments(of: "a && b || c & d").map(\.words), [["a"], ["b"], ["c"], ["d"]])
        XCTAssertEqual(commandSegments(of: "a || b").map(\.afterPipe), [false, false])
        XCTAssertEqual(
            commandSegments(of: "echo $(git st").last, CommandSegment(words: ["git", "st"], afterPipe: false))
        XCTAssertEqual(commandSegments(of: "echo `ls x").last?.words, ["ls", "x"])
        XCTAssertEqual(commandSegments(of: "git commit -m \"a | b\"").count, 1)
        XCTAssertEqual(commandSegments(of: ""), [])
    }

    func testSeparatorsInsideSingleQuotesAreText() {
        XCTAssertEqual(commandSegments(of: "echo 'a ; b && c'").count, 1)
        XCTAssertEqual(commandSegments(of: "echo a\\;b").count, 1)
    }

    func testWrappedCommand() {
        let c = ctx("sudo git co")
        XCTAssertEqual(c.kind, .command)
        XCTAssertEqual(c.segmentWords, ["git"])
        XCTAssertEqual(c.currentToken, "co")
        XCTAssertEqual(c.previousWord, "git")
        XCTAssertEqual(ctx("env FOO=1 make t").segmentWords, ["make"])
    }

    func testStrippingWrappers() {
        XCTAssertEqual(strippingWrappers(["sudo", "-E", "env", "A=1", "git", "status"]), ["git", "status"])
        XCTAssertEqual(strippingWrappers(["git", "-C", "x"]), ["git", "-C", "x"])
        XCTAssertEqual(strippingWrappers([]), [])
        XCTAssertEqual(strippingWrappers(["sudo"]), [])
    }

    func testProse() {
        let c = ctx("Can you check th")
        XCTAssertEqual(c.kind, .prose)
        XCTAssertEqual(c.previousWord, "check")
        XCTAssertEqual(c.currentToken, "th")
        XCTAssertEqual(ctx("fix the bug").kind, .prose)
    }

    func testUndecidedAndEmpty() {
        XCTAssertEqual(ctx("hel").kind, .undecided)
        XCTAssertEqual(ctx("hello wo").kind, .undecided)  // one completed word only
        let e = ctx("")
        XCTAssertEqual(e.kind, .undecided)
        XCTAssertEqual(e.currentToken, "")
        XCTAssertNil(e.previousWord)
    }

    func testShapesMakeCommand() {
        XCTAssertEqual(ctx("foo -v x").kind, .command)
        XCTAssertEqual(ctx("foo - x").kind, .prose)  // a lone "-" is not a flag
        XCTAssertEqual(ctx("foo ~/pro x").kind, .command)
        XCTAssertEqual(ctx("cd ~/pro").kind, .command)  // known tool
    }

    func testQuotesAreProse() {
        let c = ctx("git commit -m \"fix the")
        XCTAssertTrue(c.inQuotes)
        XCTAssertEqual(c.kind, .prose)
        XCTAssertEqual(c.previousWord, "fix")
        XCTAssertEqual(c.currentToken, "the")
    }

    func testSegmentStartAfterSpace() {
        let c = ctx("git status ")
        XCTAssertEqual(c.currentToken, "")
        XCTAssertEqual(c.previousWord, "status")
        XCTAssertEqual(c.segmentWords, ["git", "status"])
        let p = ctx("ls | ")
        XCTAssertTrue(p.afterPipe)
        XCTAssertEqual(p.segmentWords, [])
        XCTAssertNil(p.previousWord)
    }
}
