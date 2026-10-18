// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SeedKit

final class FigTreeTests: XCTestCase {
    let src = """
    const completionSpec: Fig.Spec = {
      name: "git",
      subcommands: [
        { name: "commit", options: [{ name: ["-m", "--message"] }, { name: "--amend" }] },
        { name: ["checkout", "co"], subcommands: [{ name: "deep", subcommands: [{ name: "deeper", subcommands: [{ name: "deepest" }] }] }] },
      ],
      options: [{ name: "--version" }],
    };
    export default completionSpec;
    """

    func testNestedSpec() {
        let s = FigSpecParser.spec(fromSource: src, command: "git")
        XCTAssertEqual(s.names, ["git"])
        XCTAssertEqual(s.options, ["--version"])
        XCTAssertEqual(s.subcommands.map(\.names), [["commit"], ["checkout", "co"]])
        XCTAssertEqual(s.subcommands[0].options, ["-m", "--message", "--amend"])
        XCTAssertEqual(s.subcommands[1].subcommands[0].subcommands[0].names, ["deeper"])
        XCTAssertEqual(s.subcommands[1].subcommands[0].subcommands[0].subcommands, [])  // maxDepth 3 cuts "deepest"
    }

    func testMaxDepthParameter() {
        let shallow = FigSpecParser.spec(fromSource: src, command: "git", maxDepth: 1)
        XCTAssertEqual(shallow.subcommands.map(\.names), [["commit"], ["checkout", "co"]])
        XCTAssertEqual(shallow.subcommands[1].subcommands, [])
        let none = FigSpecParser.spec(fromSource: src, command: "git", maxDepth: 0)
        XCTAssertEqual(none.subcommands, [])
        XCTAssertEqual(none.options, ["--version"])
    }

    func testCommentsStringsAndNonLiteralValuesDoNotDesync() {
        let source = """
        import type { Generator } from "x";
        // { name: "fake" }
        const completionSpec: Fig.Spec = {
          name: "tool",
          description: "has { braces } and [brackets] and name: \\"no\\"",
          subcommands: [
            { name: "run", description: `t ${"{"}`, args: { generators: { postProcess: (out) => out.split("\\n").map((x) => ({ name: x })) } },
              options: [{ name: "--fast", args: { name: "ignored" } }] },
            { name: "loaded", loadSpec: "other" },
            { name: `tmpl${1}` },
          ],
        };
        """
        let s = FigSpecParser.spec(fromSource: source, command: "tool")
        XCTAssertEqual(s.subcommands.map(\.names), [["run"], ["loaded"]])
        XCTAssertEqual(s.subcommands[0].options, ["--fast"])
        XCTAssertEqual(s.subcommands[0].subcommands, [])
        XCTAssertEqual(s.subcommands[1].subcommands, [])
    }

    func testNoSubcommandsOrGarbage() {
        XCTAssertEqual(FigSpecParser.spec(fromSource: "", command: "x"),
                       FigCommandSpec(names: ["x"], subcommands: [], options: []))
        XCTAssertEqual(FigSpecParser.spec(fromSource: "const a = {", command: "x").subcommands, [])
    }
}
