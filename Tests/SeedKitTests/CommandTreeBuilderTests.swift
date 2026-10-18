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
        XCTAssertEqual(u.toolCounts, ["git": 3, "grep": 1, "sudo": 1])
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
        u.ingest(example: "aa && bb ; cc || dd")
        XCTAssertEqual(u.pipeTargetCounts, ["sudo": 1, "uniq": 1])
        XCTAssertEqual(u.toolCounts["sort"], 1)
        XCTAssertEqual(u.toolCounts["sudo"], 1)
        XCTAssertEqual(u.toolCounts["aa"], 1)
        XCTAssertEqual(u.toolCounts["dd"], 1)
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
        let fig = FigCommandSpec(names: ["tt"], subcommands: [
            FigCommandSpec(names: ["a"], subcommands: [], options: []),
            FigCommandSpec(names: ["b"], subcommands: [], options: []),
            FigCommandSpec(names: ["c"], subcommands: [], options: [])], options: [])
        var u = CommandUsage()
        for _ in 0..<3 { u.ingest(example: "tt a") }
        u.ingest(example: "tt b")
        let t = buildCommandTree(specs: [fig], usage: u)
        let got = t.candidates(segmentWords: ["tt"], typed: "", afterPipe: false, limit: 5)
        // b: 1 + round(254 * ln2 / ln4) = 128; c has zero count -> 1
        XCTAssertEqual(got.map(\.text), ["a", "b", "c"])
        XCTAssertEqual(got.map(\.score), [255, 128, 1])
    }

    func testNoUsageGivesAllChildrenScoreOne() {
        let fig = FigCommandSpec(names: ["tt"], subcommands: [
            FigCommandSpec(names: ["zeta"], subcommands: [], options: []),
            FigCommandSpec(names: ["alpha"], subcommands: [], options: [])], options: [])
        let t = buildCommandTree(specs: [fig], usage: CommandUsage())
        XCTAssertTrue(t.isKnownTool("tt"))
        XCTAssertEqual(t.candidates(segmentWords: ["tt"], typed: "", afterPipe: false, limit: 5).map(\.score), [1, 1])
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
        for (tool, n) in [("aa", 3), ("bb", 2), ("cc", 1)] { for _ in 0..<n { u.ingest(example: tool) } }
        let t = buildCommandTree(specs: [], usage: u, maxTools: 2)
        XCTAssertTrue(t.isKnownTool("bb")); XCTAssertFalse(t.isKnownTool("cc"))
        let all = buildCommandTree(specs: [], usage: u, maxTools: 3)
        XCTAssertTrue(all.isKnownTool("cc"))
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

    func testPlaceholderFlagsAreCounted() {
        var u = CommandUsage()
        u.ingest(example: "foo --bar={{x}}")
        u.ingest(example: "foo -n{{5}}")
        u.ingest(example: "foo {{file}} -v")
        u.ingest(example: "foo -{{x}} --")
        XCTAssertEqual(u.flagCounts[["foo"]], ["--bar": 1, "-n": 1, "-v": 1])
    }

    func testFlagsRollUpToDeepestKnownNode() {
        let fig = FigCommandSpec(names: ["ls"], subcommands: [], options: [])
        var u = CommandUsage()
        u.ingest(example: "ls /tmp -l")
        u.ingest(example: "ls -l")
        u.ingest(example: "ls -a")
        XCTAssertEqual(u.flagCounts[["ls", "/tmp"]], ["-l": 1])
        let t = buildCommandTree(specs: [fig], usage: u)
        let got = t.candidates(segmentWords: ["ls"], typed: "-", afterPipe: false, limit: 5)
        XCTAssertEqual(got.map(\.text), ["-l", "-a"])
        XCTAssertEqual(got.map(\.score), [255, 161])
    }

    func testAliasNodesPoolFlagCounts() {
        let fig = FigCommandSpec(names: ["git"], subcommands: [
            FigCommandSpec(names: ["checkout", "co"], subcommands: [], options: [])], options: [])
        var u = CommandUsage()
        u.ingest(example: "git checkout -b x")
        u.ingest(example: "git co -b y")
        u.ingest(example: "git co -q z")
        let t = buildCommandTree(specs: [fig], usage: u)
        for alias in ["checkout", "co"] {
            let got = t.candidates(segmentWords: ["git", alias], typed: "-", afterPipe: false, limit: 5)
            XCTAssertEqual(got.map(\.text), ["-b", "-q"], alias)
            XCTAssertEqual(got.map(\.score), [255, 161], alias)
        }
    }
    // Real tldr v2.3 lines (CC BY 4.0): placeholders hold spaces and `|` alternatives.
    func testPlaceholderSpansWithSpacesAndPipesAreOneDroppedWord() {
        var u = CommandUsage()
        u.ingest(example: "xml canonic {{path/to/input.xml|URI}} > {{path/to/output.xml}}")
        u.ingest(example: "difft --syntax-highlight {{on|off}} {{path/to/file1}} {{path/to/file2}}")
        u.ingest(example: "git commit {{path/to/file1 path/to/file2 ...}}")
        u.ingest(example: "xmake config --plat={{macosx|linux|iphoneos|...}} --arch={{x86_64|i386}}")
        XCTAssertEqual(u.toolCounts, ["xml": 1, "difft": 1, "git": 1, "xmake": 1])
        XCTAssertEqual(u.pipeTargetCounts, [:])
        XCTAssertEqual(u.pathCounts, [["xml", "canonic"]: 1, ["git", "commit"]: 1, ["xmake", "config"]: 1])
        XCTAssertEqual(u.flagCounts[["difft"]], ["--syntax-highlight": 1])
        XCTAssertEqual(u.flagCounts[["xmake", "config"]], ["--plat": 1, "--arch": 1])
    }

    func testPlaceholderEndsPathAndUnterminatedPlaceholderIsSkipped() {
        var u = CommandUsage()
        u.ingest(example: "git {{some branch}} status")
        u.ingest(example: "tool {{open | xz")
        XCTAssertEqual(u.toolCounts, ["git": 1, "tool": 1, "xz": 1])
        XCTAssertEqual(u.pathCounts, [:])
    }

    func testWordsThatCannotBeCommandNamesAreNotTools() {
        var u = CommandUsage()
        for example in ["cmd 2>&1 | 2", "xx | ${EDITOR}", "xx | a=b", "xx | ...", "xx | ./run.sh", "xx | 7z a", "xx | g++ -o"] {
            u.ingest(example: example)
        }
        XCTAssertEqual(u.pipeTargetCounts, ["7z": 1, "g++": 1])
        XCTAssertEqual(u.toolCounts, ["cmd": 1, "xx": 6, "7z": 1, "g++": 1])
    }

    func testToolsNeedFigSpecOrTldrPage() {
        let fig = FigCommandSpec(names: ["git"], subcommands: [], options: [])
        var u = CommandUsage()
        for _ in 0..<5 { u.ingest(example: "stdout | grep x") }
        u.ingest(example: "git log | less")
        u.ingest(example: "ls | stdin")
        let t = buildCommandTree(specs: [fig], usage: u, pages: ["grep", "ls", "less"])
        XCTAssertEqual(t.candidates(segmentWords: [], typed: "", afterPipe: false, limit: 10).map(\.text),
                       ["grep", "git", "less", "ls"])
        XCTAssertFalse(t.isKnownTool("stdout"))
        XCTAssertFalse(t.isKnownTool("stdin"))
        let parts = buildCommandTreeParts(specs: [fig], usage: u, pages: ["grep", "ls", "less"])
        XCTAssertEqual(parts.pipeTargets.map(\.text), ["grep", "less"])
        // Without a page set every counted tool stays eligible.
        XCTAssertTrue(buildCommandTree(specs: [fig], usage: u).isKnownTool("stdout"))
    }

    // Alias pages end with the stock "View documentation for the original command" example.
    func testExamplesWhoseCommandIsTldrAreDropped() {
        var u = CommandUsage()
        u.ingest(example: "tldr git checkout")
        u.ingest(example: "sudo tldr --update")
        u.ingest(page: "gco", examples: ["tldr git-checkout", "git checkout -b x"])
        XCTAssertEqual(u.toolCounts, ["git": 1])
        XCTAssertNil(u.flagCounts[["tldr"]])
        XCTAssertNil(u.pathCounts[["tldr", "git"]])
        XCTAssertEqual(u.pathCounts[["git", "checkout"]], 1)
    }

    func testToolCountsAreDistinctPagesOutsideTheToolsFamily() {
        var u = CommandUsage()
        u.ingest(page: "cat", examples: ["cat f | grep x"])
        u.ingest(page: "dmesg", examples: ["dmesg | grep -i y", "dmesg | grep z"])
        u.ingest(page: "vegeta", examples: Array(repeating: "echo t | vegeta attack", count: 5))
        u.ingest(page: "vegeta-report", examples: ["vegeta report"])
        // grep: pages cat and dmesg, no own page. vegeta: own family only, plus its own page.
        // echo: one page outside its family, no own page. cat and dmesg: own page only.
        XCTAssertEqual(u.toolCounts, ["grep": 2, "vegeta": 1, "echo": 1, "cat": 1, "dmesg": 1])
        XCTAssertEqual(u.pipeTargetCounts, ["grep": 2, "vegeta": 1])
        // Paths and flags stay per example.
        XCTAssertEqual(u.pathCounts[["vegeta", "attack"]], 5)
        XCTAssertEqual(u.flagCounts[["grep"]], ["-i": 1])
    }

    func testOwnPageBonusOnceAndIndependentOfOrder() {
        var u = CommandUsage()
        u.ingest(page: "a", examples: ["grep x"])
        u.ingest(page: "a", examples: ["grep y"])            // same stem (linux and osx): one page
        u.ingest(page: "grep", examples: ["grep foo"])       // own page arrives after the use
        u.ingest(page: "grep", examples: ["grep bar"])
        u.ingest(page: "jq", examples: ["echo {} | gron"])   // own page, never used as a command
        u.ingest(page: "b", examples: ["sed s/a/b/ f"])
        u.ingest(page: "sed", examples: ["echo x"])          // own page does not use it
        XCTAssertEqual(u.toolCounts, ["grep": 2, "echo": 2, "gron": 1, "sed": 2])
        XCTAssertEqual(u.pipeTargetCounts, ["gron": 1])
    }

    func testCrossPageCountsDecideRankInTheBuiltTree() {
        var u = CommandUsage()
        u.ingest(page: "x", examples: ["x | grep a"])
        u.ingest(page: "y", examples: ["y | grep b"])
        u.ingest(page: "vegeta", examples: Array(repeating: "echo t | vegeta attack", count: 5))
        let t = buildCommandTree(specs: [], usage: u, pages: ["x", "y", "vegeta", "grep", "echo"])
        let parts = buildCommandTreeParts(specs: [], usage: u, pages: ["x", "y", "vegeta", "grep", "echo"])
        XCTAssertEqual(parts.pipeTargets.map(\.text), ["grep", "vegeta"])
        XCTAssertEqual(parts.pipeTargets.map(\.score), [255, 161])
        XCTAssertEqual(t.candidates(segmentWords: [], typed: "", afterPipe: false, limit: 2).map(\.text), ["grep", "echo"])
    }

    func testMaxToolsTiesBrokenByOwnFamilyPageCount() {
        var u = CommandUsage()
        u.ingest(page: "aa", examples: ["npm install", "gcloud init"])
        u.ingest(page: "bb", examples: ["npm test", "gcloud auth"])
        let pages: Set<String> = ["aa", "bb", "npm", "npm-run", "npm-ci", "gcloud", "gcloud-sql", "npmx"]
        // Both used by 2 other pages; npm has 3 own-family pages (npm, npm-ci, npm-run; not npmx),
        // gcloud 2. Name order alone would put gcloud first.
        XCTAssertEqual(u.toolCounts, ["npm": 2, "gcloud": 2])
        let parts = buildCommandTreeParts(specs: [], usage: u, maxTools: 1, pages: pages)
        XCTAssertEqual(parts.tools.map(\.name), ["npm"])
        let both = buildCommandTreeParts(specs: [], usage: u, maxTools: 2, pages: pages)
        XCTAssertEqual(both.tools.map(\.name), ["npm", "gcloud"])
        // Without family information the name decides.
        XCTAssertEqual(buildCommandTreeParts(specs: [], usage: u, maxTools: 1, pages: nil).tools.map(\.name), ["gcloud"])
    }

    func testSingleCharactersAndReservedWordsAreNotCommands() {
        for word in ["q", "s", "w", "if", "then", "else", "elif", "fi", "for", "while", "until", "do",
                     "done", "case", "esac", "function", "select", "in", "{", "}"] {
            XCTAssertFalse(isCommandName(word), word)
        }
        for word in ["cd", "export", "source", "exit", "eval", "alias", "ls", "fio", "done2"] {
            XCTAssertTrue(isCommandName(word), word)
        }
        var u = CommandUsage()
        u.ingest(page: "clifm", examples: ["q", "s *.png", "for f in *; do echo $f; done", "cd {{path}}", "ls | q"])
        // `do echo $f` starts with a reserved word, so the segment adds nothing.
        XCTAssertEqual(u.toolCounts, ["cd": 1, "ls": 1])
        XCTAssertEqual(u.pipeTargetCounts, [:])
        let fig = FigCommandSpec(names: ["q"], subcommands: [], options: ["--help"])
        XCTAssertFalse(buildCommandTree(specs: [fig], usage: u).isKnownTool("q"))
    }

    func testWrappersAreCreditedAlongsideTheWrappedCommand() {
        var u = CommandUsage()
        u.ingest(page: "find", examples: ["find . -name {{x}} | xargs rm"])
        u.ingest(page: "apt", examples: ["sudo apt update", "sudo env FOO=1 nohup apt upgrade"])
        // find: own page only. xargs: tool and pipe target (first word after `|`); rm: tool only.
        // sudo, env, nohup: tools on page apt (FOO=1 is an assignment); apt: own family only,
        // plus its own page.
        XCTAssertEqual(u.toolCounts, ["find": 1, "xargs": 1, "rm": 1, "sudo": 1, "env": 1, "nohup": 1, "apt": 1])
        XCTAssertEqual(u.pipeTargetCounts, ["xargs": 1])
        XCTAssertEqual(u.pathCounts[["apt", "update"]], 1)
        XCTAssertNil(u.flagCounts[["sudo"]])
    }

    func testHeldOutPageCountsAsExistingButItsExamplesAreSkipped() {
        // "npm" is held out under the FNV rule; "npm-ci" is not.
        XCTAssertTrue(TldrHoldout.isHeldOut(pageStem: "npm"))
        XCTAssertFalse(TldrHoldout.isHeldOut(pageStem: "npm-ci"))
        var u = CommandUsage()
        u.ingest(page: "npm", markdown: "# npm\n\n- Install:\n\n`npm install --global {{pkg}}`\n")
        u.ingest(page: "npm-ci", markdown: "- Clean install:\n\n`npm ci --omit dev`\n")
        u.ingest(page: "nvm", markdown: "- Then:\n\n`npm ci`\n")
        // One page outside the family (nvm) plus the held-out own page.
        XCTAssertEqual(u.toolCounts, ["npm": 2])
        XCTAssertEqual(u.pathCounts, [["npm", "ci"]: 2])
        XCTAssertEqual(u.flagCounts, [["npm", "ci"]: ["--omit": 1]])
        // Admitted through the held-out page alone (no Fig spec).
        let t = buildCommandTree(specs: [], usage: u, pages: ["npm", "npm-ci", "nvm"])
        XCTAssertTrue(t.isKnownTool("npm"))
        XCTAssertFalse(buildCommandTree(specs: [], usage: u, pages: ["npm-ci", "nvm"]).isKnownTool("npm"))
    }
}
