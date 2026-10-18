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
    // Shape of withfig/autocomplete src/git.ts (MIT): helper functions and exported generator
    // tables precede the spec, option lists live in consts, `export default` names the spec.
    func testSpecLocatedThroughExportDefaultAfterHelpers() {
        let source = """
        const filterMessages = (out: string): string => {
          return out.startsWith("warning:") ? out.split("\\n").slice(1).join("\\n") : out;
        };
        export const gitGenerators: Record<string, Fig.Generator> = {
          commits: { script: ["git", "log"], postProcess: function (out) { return [{ name: "fake" }]; } },
        };
        const addOptions: Fig.Option[] = [
          { name: ["-n", "--dry-run"], description: "Dry run" },
          { name: ["-v", "--verbose"] },
        ];
        const completionSpec: Fig.Spec = {
          name: "git",
          generateSpec: async (_, executeShellCommand) => {
            const { stdout } = await executeShellCommand({ command: "git", args: ["help", "-a"] });
            return { name: "git", subcommands: [{ name: "generated" }] };
          },
          options: [{ name: "--version" }],
          subcommands: [
            { name: "commit", options: [{ name: ["-m", "--message"] }] },
            { name: "add", options: addOptions, args: { generators: gitGenerators.commits } },
          ],
        };
        export default completionSpec;
        """
        let s = FigSpecParser.spec(fromSource: source, command: "git")
        XCTAssertEqual(s.options, ["--version"])
        XCTAssertEqual(s.subcommands.map(\.names), [["commit"], ["add"]])
        XCTAssertEqual(s.subcommands[1].options, ["-n", "--dry-run", "-v", "--verbose"])
    }

    // Shape of withfig/autocomplete src/docker.ts (MIT): a `Record` of shared subcommands
    // referenced as `sharedCommands.build`, plus spreads and calls in member arrays.
    func testMemberReferencesSpreadsAndCalls() {
        let source = """
        const containersArg = { name: "container" };
        const sharedCommands: Record<string, Fig.Subcommand> = {
          build: { name: "build", options: [{ name: ["-t", "--tag"] }] },
          ps: { name: ["ps", "list"], args: containersArg },
        };
        const extraCommands = [{ name: "events" }, sharedCommands.ps];
        const globalOptions: Fig.Option[] = [{ name: "--debug" }];
        const completionSpec: Fig.Spec = {
          name: "docker",
          subcommands: [
            sharedCommands.build,
            { ...sharedCommands.build, name: "buildx", options: [...globalOptions, { name: "--push" }] },
            ...extraCommands,
            makeCommand("generated"),
            sharedCommands["computed"],
            missingConst,
            { name: "image", subcommands: [sharedCommands.build] },
          ],
          options: globalOptions,
        };
        export default completionSpec;
        """
        let s = FigSpecParser.spec(fromSource: source, command: "docker")
        XCTAssertEqual(s.subcommands.map(\.names), [["build"], ["buildx"], ["events"], ["ps", "list"], ["image"]])
        XCTAssertEqual(s.subcommands[0].options, ["-t", "--tag"])
        XCTAssertEqual(s.subcommands[1].options, ["--debug", "--push"])
        XCTAssertEqual(s.subcommands[4].subcommands.map(\.names), [["build"]])
        XCTAssertEqual(s.subcommands[4].subcommands[0].options, ["-t", "--tag"])
        XCTAssertEqual(s.options, ["--debug"])
    }

    func testSpreadDoesNotOverrideLaterKeysAndLaterSpreadOverridesEarlierKeys() {
        let source = """
        const base = { name: "base", options: [{ name: "--a" }] };
        const completionSpec: Fig.Spec = {
          name: "t",
          subcommands: [
            { name: "first", ...base },
            { ...base, name: "second" },
          ],
        };
        export default completionSpec;
        """
        let s = FigSpecParser.spec(fromSource: source, command: "t")
        XCTAssertEqual(s.subcommands.map(\.names), [["base"], ["second"]])
        XCTAssertEqual(s.subcommands.map(\.options), [["--a"], ["--a"]])
    }

    func testSelfReferenceAndSpreadCyclesTerminate() {
        let source = """
        const loop: Fig.Subcommand = { name: "loop", subcommands: [loop] };
        const x = { ...y, name: "x" };
        const y = { ...x };
        const completionSpec: Fig.Spec = { name: "t", subcommands: [loop, x, ...arr] };
        const arr = [...arr];
        export default completionSpec;
        """
        let s = FigSpecParser.spec(fromSource: source, command: "t")
        XCTAssertEqual(s.subcommands.map(\.names), [["loop"], ["x"]])
        XCTAssertEqual(s.subcommands[0].subcommands[0].subcommands[0].names, ["loop"])
        XCTAssertEqual(s.subcommands[0].subcommands[0].subcommands[0].subcommands, [])
    }

    func testExportDefaultObjectLiteral() {
        let source = """
        const helper = () => { return { name: "fake" }; };
        export default { name: "t", subcommands: [{ name: "run" }] };
        """
        XCTAssertEqual(FigSpecParser.spec(fromSource: source, command: "t").subcommands.map(\.names), [["run"]])
    }
}
