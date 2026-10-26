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

    // MARK: - `&` in redirections is not a separator

    func testFdDuplicationIsNotASeparator() {
        XCTAssertEqual(commandSegments(of: "make 2>&1").map(\.words), [["make", "2>&1"]])
        XCTAssertEqual(commandSegments(of: "echo hi >&2").map(\.words), [["echo", "hi", ">&2"]])
        XCTAssertEqual(commandSegments(of: "cat <&3").map(\.words), [["cat", "<&3"]])
    }

    func testAmpersandRedirectIsNotASeparator() {
        XCTAssertEqual(commandSegments(of: "make &>log").map(\.words), [["make", "&>log"]])
        XCTAssertEqual(commandSegments(of: "make &>>log").map(\.words), [["make", "&>>log"]])
    }

    func testPipeAmpersandIsAPipe() {
        XCTAssertEqual(
            commandSegments(of: "make |& grep err"),
            [
                CommandSegment(words: ["make"], afterPipe: false),
                CommandSegment(words: ["grep", "err"], afterPipe: true),
            ])
    }

    func testRedirectThenSeparatorsStillSplit() {
        // `2>&1` stays in its segment; the `&&` and the trailing `&` still split.
        XCTAssertEqual(
            commandSegments(of: "make 2>&1 && ls & git").map(\.words),
            [["make", "2>&1"], ["ls"], ["git"]])
        XCTAssertEqual(commandSegments(of: "sleep 1 &").map(\.words), [["sleep", "1"]])
    }

    func testTypingAfterRedirectStaysInCommand() {
        // Before: the `&` of `2>&1` opened a new segment, so `t` was read as a fresh command.
        let c = ctx("make 2>&1 t")
        XCTAssertEqual(c.segmentWords, ["make", "2>&1"])
        XCTAssertEqual(c.previousWord, lookupWord(fromToken: "2>&1").word)
    }

    // MARK: - Wrapper option values are not the command

    func testWrapperOptionValueIsSkipped() {
        XCTAssertEqual(strippingWrappers(["sudo", "-u", "alice", "git", "pull"]), ["git", "pull"])
        XCTAssertEqual(strippingWrappers(["sudo", "-g", "wheel", "ls"]), ["ls"])
        XCTAssertEqual(strippingWrappers(["env", "-u", "HOME", "make"]), ["make"])
        XCTAssertEqual(strippingWrappers(["doas", "-u", "bob", "ls"]), ["ls"])
        XCTAssertEqual(strippingWrappers(["nice", "-n", "10", "make"]), ["make"])
        XCTAssertEqual(strippingWrappers(["watch", "-n", "1", "ls"]), ["ls"])
        XCTAssertEqual(strippingWrappers(["xargs", "-I", "{}", "cp"]), ["cp"])
        XCTAssertEqual(strippingWrappers(["sudo", "--user", "alice", "ls"]), ["ls"])
    }

    func testWrapperClusteredOptionValue() {
        // `-Eu alice`: the cluster ends in a value letter, so the next word is its value.
        XCTAssertEqual(strippingWrappers(["sudo", "-Eu", "alice", "ls"]), ["ls"])
        // `-ualice`: the value is attached, so the next word is the command.
        XCTAssertEqual(strippingWrappers(["sudo", "-ualice", "ls"]), ["ls"])
        // `-ut`: `u` takes the rest (`t`) as its value; `t` is not read as an option.
        XCTAssertEqual(strippingWrappers(["sudo", "-ut", "ls"]), ["ls"])
    }

    func testWrapperFlagWithoutValueKeepsNextWord() {
        // `-E` and `-i` take no value, so the following word is the command.
        XCTAssertEqual(strippingWrappers(["sudo", "-E", "ls"]), ["ls"])
        XCTAssertEqual(strippingWrappers(["env", "-i", "make"]), ["make"])
        // A value letter of one wrapper is not one for another: `env -n` is not `nice -n`.
        XCTAssertEqual(strippingWrappers(["env", "-n", "make"]), ["make"])
    }

    func testWrapperValueAtEndOfLine() {
        XCTAssertEqual(strippingWrappers(["sudo", "-u"]), [])
        XCTAssertEqual(strippingWrappers(["sudo", "-u", "alice"]), [])
    }

    func testWrappedCommandAfterUserOption() {
        let c = ctx("sudo -u alice git co")
        XCTAssertEqual(c.kind, .command)
        XCTAssertEqual(c.segmentWords, ["git"])
        XCTAssertEqual(c.currentToken, "co")
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
