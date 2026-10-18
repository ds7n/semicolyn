// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
import SemicolynKit
@testable import SeedKit

final class CommandTreeBuilderTests: XCTestCase {
    func testUsageCounting() {
        var u = CommandUsage()
        u.ingest(example: "git commit -m {{message}}")
        u.ingest(example: "git commit --amend")
        u.ingest(example: "sudo git status | grep -i {{x}}")
        XCTAssertEqual(u.toolCounts, ["git": 3, "grep": 1])
        XCTAssertEqual(u.pathCounts[["git", "commit"]], 2)
        XCTAssertEqual(u.flagCounts[["git", "commit"]], ["-m": 1, "--amend": 1])
        XCTAssertEqual(u.flagCounts[["grep"]], ["-i": 1])
        XCTAssertEqual(u.pipeTargetCounts, ["grep": 1])
    }

    func testUsagePathDepthPlaceholdersAndFlagCutting() {
        var u = CommandUsage()
        u.ingest(example: "docker compose up -d --scale=3 web")
        XCTAssertEqual(u.pathCounts[["docker", "compose"]], 1)
        XCTAssertEqual(u.pathCounts[["docker", "compose", "up"]], 1)
        XCTAssertNil(u.pathCounts[["docker", "compose", "up", "web"]])
        XCTAssertEqual(u.flagCounts[["docker", "compose", "up"]], ["-d": 1, "--scale": 1])

        var p = CommandUsage()
        p.ingest(example: "ssh {{host}} ls")
        XCTAssertEqual(p.toolCounts, ["ssh": 1])
        XCTAssertNil(p.pathCounts[["ssh", "ls"]])
        XCTAssertTrue(p.pathCounts.isEmpty)

        var o = CommandUsage()
        o.ingest(example: "{{cmd}} --help")
        o.ingest(example: "")
        XCTAssertTrue(o.toolCounts.isEmpty)
    }

    func testPipeTargetsOnlyAfterSinglePipeAndStripWrappers() {
        var u = CommandUsage()
        u.ingest(example: "cat f | sudo -n sort | uniq -c")
        u.ingest(example: "a && b ; c || d")
        XCTAssertEqual(u.pipeTargetCounts, ["sort": 1, "uniq": 1])
        XCTAssertEqual(u.toolCounts["sort"], 1)
        XCTAssertEqual(u.toolCounts["a"], 1)
        XCTAssertEqual(u.flagCounts[["uniq"]], ["-c": 1])
    }

    func testBuildRanksByUsage() {
        let fig = FigCommandSpec(names: ["git"], subcommands: [
            FigCommandSpec(names: ["status"], subcommands: [], options: []),
            FigCommandSpec(names: ["commit"], subcommands: [], options: ["-m", "--amend", "--help"])], options: [])
        var u = CommandUsage()
        for _ in 0..<3 { u.ingest(example: "git commit -m x") }
        u.ingest(example: "git status")
        let t = buildCommandTree(specs: [fig], usage: u)
        XCTAssertEqual(t.candidates(segmentWords: ["git"], typed: "", afterPipe: false, limit: 5).map(\.text), ["commit", "status"])
        XCTAssertEqual(t.candidates(segmentWords: ["git", "commit"], typed: "-", afterPipe: false, limit: 5).map(\.text), ["-m", "--help"])
        XCTAssertEqual(t.candidates(segmentWords: ["git"], typed: "", afterPipe: false, limit: 1).first?.score, 255)
    }

    func testScoreFormulaAndZeroCountSibling() {
        let fig = FigCommandSpec(names: ["t"], subcommands: [
            FigCommandSpec(names: ["a"], subcommands: [], options: []),
            FigCommandSpec(names: ["b"], subcommands: [], options: []),
            FigCommandSpec(names: ["c"], subcommands: [], options: [])], options: [])
        var u = CommandUsage()
        for _ in 0..<3 { u.ingest(example: "t a") }
        u.ingest(example: "t b")
        let t = buildCommandTree(specs: [fig], usage: u)
        let got = t.candidates(segmentWords: ["t"], typed: "", afterPipe: false, limit: 5)
        // b: 1 + round(254 * ln2 / ln4) = 128; c has zero count -> 1
        XCTAssertEqual(got.map(\.text), ["a", "b", "c"])
        XCTAssertEqual(got.map(\.score), [255, 128, 1])
    }

    func testNoUsageGivesAllChildrenScoreOne() {
        let fig = FigCommandSpec(names: ["t"], subcommands: [
            FigCommandSpec(names: ["zeta"], subcommands: [], options: []),
            FigCommandSpec(names: ["alpha"], subcommands: [], options: [])], options: [])
        let t = buildCommandTree(specs: [fig], usage: CommandUsage())
        XCTAssertTrue(t.isKnownTool("t"))
        XCTAssertEqual(t.candidates(segmentWords: ["t"], typed: "", afterPipe: false, limit: 5).map(\.score), [1, 1])
    }

    func testAliasesBecomeSeparateChildren() {
        let fig = FigCommandSpec(names: ["git"], subcommands: [
            FigCommandSpec(names: ["checkout", "co"], subcommands: [
                FigCommandSpec(names: ["deep"], subcommands: [], options: [])], options: [])], options: [])
        var u = CommandUsage()
        u.ingest(example: "git checkout")
        let t = buildCommandTree(specs: [fig], usage: u)
        let got = t.candidates(segmentWords: ["git"], typed: "", afterPipe: false, limit: 5)
        XCTAssertEqual(got.map(\.text), ["checkout", "co"])
        XCTAssertEqual(got.map(\.score), [255, 255])
        XCTAssertEqual(t.candidates(segmentWords: ["git", "co"], typed: "", afterPipe: false, limit: 5).map(\.text), ["deep"])
    }

    func testMaxToolsBoundary() {
        var u = CommandUsage()
        for (tool, n) in [("a", 3), ("b", 2), ("c", 1)] { for _ in 0..<n { u.ingest(example: tool) } }
        let t = buildCommandTree(specs: [], usage: u, maxTools: 2)
        XCTAssertTrue(t.isKnownTool("b")); XCTAssertFalse(t.isKnownTool("c"))
        let all = buildCommandTree(specs: [], usage: u, maxTools: 3)
        XCTAssertTrue(all.isKnownTool("c"))
    }

    func testPipeTargetsScored() {
        var u = CommandUsage()
        for _ in 0..<3 { u.ingest(example: "x | grep a") }
        u.ingest(example: "x | wc -l")
        let t = buildCommandTree(specs: [], usage: u)
        let got = t.candidates(segmentWords: [], typed: "", afterPipe: true, limit: 2)
        XCTAssertEqual(got.map(\.text), ["grep", "wc"])
        XCTAssertEqual(got.map(\.score), [255, 128])
    }

    func testSerializationLimitsRespected() {
        let many = (0..<300).map { FigCommandSpec(names: ["sub\($0)"], subcommands: [], options: ["--f\($0)"]) }
        let long = String(repeating: "x", count: 256)
        let fig = FigCommandSpec(names: ["big", long], subcommands: many + [FigCommandSpec(names: [long], subcommands: [], options: [])],
                                 options: (0..<300).map { "--o\($0)" } + ["--" + long])
        var u = CommandUsage()
        u.ingest(example: "big sub299")
        let t = buildCommandTree(specs: [fig], usage: u)
        XCTAssertFalse(t.isKnownTool(long))
        let bytes = t.serialize()  // would trap on >255 children, flags, or an over-long name
        let back = CommandTree(deserializing: bytes)
        XCTAssertNotNil(back)
        let kids = t.candidates(segmentWords: ["big"], typed: "s", afterPipe: false, limit: 1000)
        XCTAssertEqual(kids.count, 255)
        XCTAssertEqual(kids.first?.text, "sub299")
        XCTAssertEqual(t.candidates(segmentWords: ["big", "sub0"], typed: "-", afterPipe: false, limit: 1000).count, 0)
    }
}
