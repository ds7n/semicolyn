// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

import XCTest

@testable import SemicolynKit

final class CommandTreeTests: XCTestCase {
    func f(_ s: String, _ n: UInt8) -> ScoredWord { .init(text: s, score: n) }
    var tree: CommandTree {
        CommandTree(
            tools: [
                CommandNode(
                    name: "git", score: 255,
                    children: [
                        CommandNode(name: "status", score: 255, children: [], flags: []),
                        CommandNode(name: "commit", score: 200, children: [], flags: [f("-m", 255), f("--amend", 100)]),
                        CommandNode(name: "push", score: 150, children: [], flags: []),
                    ], flags: [f("--version", 50)]),
                CommandNode(
                    name: "docker", score: 180,
                    children: [
                        CommandNode(name: "ps", score: 255, children: [], flags: []),
                        CommandNode(name: "run", score: 200, children: [], flags: []),
                    ], flags: []),
                CommandNode(name: "grep", score: 150, children: [], flags: [f("-i", 255), f("-r", 200)]),
                CommandNode(name: "ls", score: 200, children: [], flags: [f("-l", 255), f("-a", 240)]),
            ],
            pipeTargets: [f("grep", 255), f("sort", 200), f("head", 150)])
    }

    func c(_ w: [String], _ t: String, pipe: Bool = false, _ n: Int = 10) -> [String] {
        tree.candidates(segmentWords: w, typed: t, afterPipe: pipe, limit: n).map(\.text)
    }

    func testKnownTool() {
        XCTAssertTrue(tree.isKnownTool("git"))
        XCTAssertFalse(tree.isKnownTool("Git"))
        XCTAssertFalse(tree.isKnownTool("gi"))
    }

    func testTopLevel() {
        XCTAssertEqual(c([], "g"), ["git", "grep"])
        XCTAssertEqual(c([], "", pipe: true, 6), ["grep", "sort", "head", "git", "ls", "docker"])
        XCTAssertEqual(c([], "", pipe: true, 3), ["grep", "sort", "head"])
    }

    func testContextual() {
        XCTAssertEqual(c(["git"], ""), ["status", "commit", "push"])
        XCTAssertEqual(c(["git"], "c"), ["commit"])
        XCTAssertEqual(c(["git"], "p"), ["push"])  // never docker's "ps"
        XCTAssertEqual(c(["git"], "-"), ["--version"])
        XCTAssertEqual(c(["git", "commit"], "-"), ["-m", "--amend"])
        XCTAssertEqual(c(["git", "commit", "-m"], ""), ["-m", "--amend"])
        XCTAssertEqual(c(["ls"], ""), ["-l", "-a"])
        XCTAssertEqual(c(["docker"], "r"), ["run"])
    }

    func testStopsAndUnknown() {
        XCTAssertEqual(c(["foo"], ""), [])
        XCTAssertEqual(c(["git", "status", "x"], ""), [])
        XCTAssertEqual(c(["grep", "x"], "-"), ["-i", "-r"])
        XCTAssertEqual(c(["git"], "", 0), [])
    }

    func testRoundTripAndFailClosed() throws {
        let blob = tree.serialize()
        let back = try XCTUnwrap(CommandTree(deserializing: blob))
        XCTAssertEqual(
            back.candidates(segmentWords: ["git", "commit"], typed: "-", afterPipe: false, limit: 5).map(\.text),
            ["-m", "--amend"])
        XCTAssertNil(CommandTree(deserializing: Array(blob.dropLast())))
        XCTAssertNil(CommandTree(deserializing: blob + [1]))
        XCTAssertNil(CommandTree(deserializing: [0x47, 0x43, 0x4d, 0x54, 2]))
    }

    func testDepthLimit() {
        func chain(_ d: Int) -> CommandNode {
            d == 0
                ? CommandNode(name: "x", score: 1, children: [], flags: [])
                : CommandNode(name: "x", score: 1, children: [chain(d - 1)], flags: [])
        }
        XCTAssertNotNil(CommandTree(deserializing: CommandTree(tools: [chain(3)], pipeTargets: []).serialize()))  // 4 levels
        XCTAssertNil(CommandTree(deserializing: CommandTree(tools: [chain(4)], pipeTargets: []).serialize()))  // 5 levels
    }
}
