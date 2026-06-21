// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SeedKit

/// FigSpecParser — Core tier. Extracts top-level (command, subcommand)/(command,
/// flag) pairs from a Fig TypeScript completion spec, robust to TS noise. See
/// `2026-06-21-predictor-fig-ingestion-design`.
final class FigSpecParserTests: XCTestCase {
    /// Set of `next` members the parser attributes to `command`.
    private func members(_ source: String, command: String) -> Set<String> {
        let pairs = FigSpecParser.invocations(fromSpec: source, command: command)
        // Every pair is [command, member].
        for p in pairs { XCTAssertEqual(p.first, command, "every pair leads with the command") }
        return Set(pairs.compactMap { $0.count == 2 ? $0[1] : nil })
    }

    func testExtractsTopLevelSubcommandsAndOptions() {
        let src = """
        const completionSpec: Fig.Spec = {
          name: "git",
          subcommands: [
            { name: "commit", description: "Record changes" },
            { name: "status" },
          ],
          options: [
            { name: "--version" },
          ],
        };
        export default completionSpec;
        """
        XCTAssertEqual(members(src, command: "git"), ["commit", "status", "--version"])
    }

    func testNameAliasArrayEmitsEachAlias() {
        let src = """
        const c: Fig.Spec = {
          name: "git",
          subcommands: [{ name: ["status", "st"] }],
          options: [{ name: ["-m", "--message"] }],
        };
        """
        XCTAssertEqual(members(src, command: "git"), ["status", "st", "-m", "--message"])
    }

    func testArgsNameIsNotExtracted() {
        // args.name is a placeholder ("msg"/"path"), not a subcommand or flag.
        let src = """
        const c: Fig.Spec = {
          name: "git",
          subcommands: [
            { name: "commit", options: [{ name: "--message", args: { name: "msg" } }] },
          ],
          args: { name: "path" },
        };
        """
        let m = members(src, command: "git")
        XCTAssertTrue(m.contains("commit"))
        XCTAssertFalse(m.contains("msg"), "args.name must never be extracted")
        XCTAssertFalse(m.contains("path"), "top-level args.name must never be extracted")
    }

    func testNestedSubcommandsAndOptionsNotExtracted() {
        // Only the top-level command's direct members; "--message" belongs to the
        // nested "commit" subcommand and must not be attributed to "git".
        let src = """
        const c: Fig.Spec = {
          name: "git",
          subcommands: [
            { name: "commit", options: [{ name: "--message" }],
              subcommands: [{ name: "amend" }] },
          ],
        };
        """
        XCTAssertEqual(members(src, command: "git"), ["commit"],
                       "nested members must not attribute to the top command")
    }

    func testCommentsAreIgnored() {
        let src = """
        const c: Fig.Spec = {
          name: "git",
          // subcommands: [{ name: "ghost" }],
          /* options: [{ name: "--phantom" }] */
          subcommands: [{ name: "real" }],
        };
        """
        XCTAssertEqual(members(src, command: "git"), ["real"],
                       "names inside comments must not be extracted")
    }

    func testTemplateAndFunctionBodyBracesDoNotBreakParsing() {
        // A generator with a function body + template literal carries {} and ${}
        // that must not desync brace tracking.
        let src = #"""
        import { filepaths } from "@fig/autocomplete-generators";
        const gen = { script: (ctx) => { return `ls ${ctx[0]}`; }, postProcess: (o) => { return o; } };
        const c: Fig.Spec = {
          name: "kubectl",
          args: { generators: gen },
          subcommands: [{ name: "get", args: { name: "resource", generators: gen } }],
          options: [{ name: "--namespace" }],
        };
        """#
        XCTAssertEqual(members(src, command: "kubectl"), ["get", "--namespace"])
    }

    func testTemplateLiteralNameIsSkipped() {
        // A name built from a template can't be a literal token; skip it, keep the rest.
        let src = #"""
        const c: Fig.Spec = {
          name: "tool",
          subcommands: [{ name: `dyn${x}` }, { name: "plain" }],
        };
        """#
        XCTAssertEqual(members(src, command: "tool"), ["plain"])
    }

    func testSpecOwnNameNotEmittedAsMember() {
        let src = """
        const c: Fig.Spec = { name: "solo", options: [{ name: "--flag" }] };
        """
        XCTAssertEqual(members(src, command: "solo"), ["--flag"],
                       "the spec's own name is the command, not a member of itself")
    }

    func testUnbalancedRegexLiteralDoesNotDesyncStack() {
        // A regex with an unbalanced `]`/`}` must be consumed opaquely; otherwise
        // its bracket pops a frame early and drops every later member.
        let src = #"""
        const c: Fig.Spec = {
          name: "sed",
          subcommands: [
            { name: "first", args: { generators: { postProcess: (o) => o.split(/]/) } } },
            { name: "second" },
          ],
          options: [{ name: "--quiet" }],
        };
        """#
        XCTAssertEqual(members(src, command: "sed"), ["first", "second", "--quiet"],
                       "an unbalanced bracket inside a regex must not drop later members")
    }

    func testDivisionOperatorIsNotMistakenForRegex() {
        // `a / b` is division; mis-consuming it as a regex would swallow real tokens.
        let src = """
        const c: Fig.Spec = {
          name: "calc",
          args: { generators: { postProcess: (o) => o.length / 2 } },
          options: [{ name: "--round" }],
        };
        """
        XCTAssertEqual(members(src, command: "calc"), ["--round"])
    }

    func testNoSubcommandsOrOptionsReturnsEmpty() {
        let src = """
        const c: Fig.Spec = { name: "noop", args: { name: "x" } };
        """
        XCTAssertEqual(FigSpecParser.invocations(fromSpec: src, command: "noop"), [])
    }
}
