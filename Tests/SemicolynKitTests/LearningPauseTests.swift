// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// Privacy P-M6 part 2: learning pauses while the active tmux pane runs a full-screen
/// program or a REPL (read from the tmux title our launch configures), or, without
/// tmux, while the terminal itself is on the alternate screen.
final class LearningPauseTests: XCTestCase {

    // MARK: full-screen suffix

    func testFullScreenSuffixPausesWithTheCommand() {
        XCTAssertEqual(learningPause(forTitle: "vi (full screen)"), .fullScreen(command: "vi"))
        XCTAssertEqual(learningPause(forTitle: "less (full screen)"), .fullScreen(command: "less"))
    }

    /// The suffix wins over the REPL list: a REPL in full-screen mode reports full screen.
    func testFullScreenSuffixOnAReplReportsFullScreen() {
        XCTAssertEqual(learningPause(forTitle: "python3 (full screen)"), .fullScreen(command: "python3"))
    }

    /// Our format always ends in the exact suffix; a near miss is not ours.
    func testSuffixMustMatchExactly() {
        XCTAssertNil(learningPause(forTitle: "vi (full screen"))
        XCTAssertNil(learningPause(forTitle: "vi(full screen)"))
        XCTAssertNil(learningPause(forTitle: "vi (Full Screen)"))
        XCTAssertNil(learningPause(forTitle: "vi (full screen) "))
    }

    // MARK: REPL list

    func testVersionedReplNamePausesAsRepl() {
        XCTAssertEqual(learningPause(forTitle: "python3.12"), .repl(command: "python3.12"))
        XCTAssertEqual(learningPause(forTitle: "python3"), .repl(command: "python3"))
        XCTAssertEqual(learningPause(forTitle: "python"), .repl(command: "python"))
    }

    func testReplMatchIsCaseInsensitiveAndKeepsTheOriginalName() {
        XCTAssertEqual(learningPause(forTitle: "PSQL"), .repl(command: "PSQL"))
    }

    func testSqlite3NormalizesToSqlite() {
        XCTAssertEqual(learningPause(forTitle: "sqlite3"), .repl(command: "sqlite3"))
        XCTAssertTrue(replCommands.contains("sqlite"))
        XCTAssertFalse(replCommands.contains("sqlite3"))
    }

    func testReplListIsTheSpecList() {
        XCTAssertEqual(replCommands, [
            "python", "ipython", "bpython", "node", "deno", "bun", "irb", "pry", "ghci",
            "lua", "r", "julia", "php", "psql", "mysql", "mariadb", "sqlite", "redis-cli",
            "mongosh", "mongo", "sqlplus", "cqlsh", "clickhouse-client",
        ])
    }

    func testHyphenatedAndShortReplNamesPause() {
        XCTAssertEqual(learningPause(forTitle: "redis-cli"), .repl(command: "redis-cli"))
        XCTAssertEqual(learningPause(forTitle: "R"), .repl(command: "R"))
        XCTAssertEqual(learningPause(forTitle: "lua5.4"), .repl(command: "lua5.4"))
    }

    // MARK: titles that pause nothing

    func testShellsPauseNothing() {
        XCTAssertNil(learningPause(forTitle: "bash"))
        XCTAssertNil(learningPause(forTitle: "zsh"))
    }

    func testEmptyAndForeignTitlesPauseNothing() {
        XCTAssertNil(learningPause(forTitle: ""))
        XCTAssertNil(learningPause(forTitle: "my vi notes"))
        XCTAssertNil(learningPause(forTitle: "vim-like-name"))
        XCTAssertNil(learningPause(forTitle: "user@host: ~/src"))
    }

    /// Only trailing digits and dots are stripped: a REPL name with a different
    /// prefix or a non-version suffix is not in the list.
    func testOnlyTrailingVersionCharactersAreStripped() {
        XCTAssertNil(learningPause(forTitle: "python-config"))
        XCTAssertNil(learningPause(forTitle: "3python"))
        XCTAssertNil(learningPause(forTitle: "nodemon"))
        XCTAssertNil(learningPause(forTitle: "3.12"))
    }

    // MARK: display title

    func testDisplayTitleStripsTheSuffix() {
        XCTAssertEqual(displayTitle(fromTmuxTitle: "less (full screen)"), "less")
        XCTAssertEqual(displayTitle(fromTmuxTitle: "bash"), "bash")
        XCTAssertEqual(displayTitle(fromTmuxTitle: "vi (full screen"), "vi (full screen")
        XCTAssertEqual(tmuxFullScreenTitleSuffix, " (full screen)")
    }

    // MARK: resolution per session kind

    /// With tmux, the outer terminal is on the alternate screen all session, so only the
    /// title decides.
    func testTmuxSessionUsesTheTitleAndIgnoresTheAlternateScreen() {
        XCTAssertNil(resolvedLearningPause(tmuxAttached: true, titlePause: nil, alternateScreen: true))
        XCTAssertEqual(resolvedLearningPause(tmuxAttached: true, titlePause: .fullScreen(command: "vi"),
                                             alternateScreen: true),
                       .fullScreen(command: "vi"))
        XCTAssertEqual(resolvedLearningPause(tmuxAttached: true, titlePause: .repl(command: "node"),
                                             alternateScreen: false),
                       .repl(command: "node"))
    }

    /// Without tmux, the alternate screen decides and titles (not produced by our
    /// format) pause nothing.
    func testRawSessionUsesTheAlternateScreenAndIgnoresTitles() {
        XCTAssertEqual(resolvedLearningPause(tmuxAttached: false, titlePause: nil, alternateScreen: true),
                       .altScreen)
        XCTAssertNil(resolvedLearningPause(tmuxAttached: false, titlePause: .repl(command: "python3"),
                                           alternateScreen: false))
        XCTAssertEqual(resolvedLearningPause(tmuxAttached: false, titlePause: .fullScreen(command: "vi"),
                                             alternateScreen: true),
                       .altScreen)
    }

    // MARK: log fields

    func testLogFields() {
        XCTAssertEqual(LearningPause.fullScreen(command: "vi").logKind, "fullScreen")
        XCTAssertEqual(LearningPause.fullScreen(command: "vi").command, "vi")
        XCTAssertEqual(LearningPause.repl(command: "psql").logKind, "repl")
        XCTAssertEqual(LearningPause.repl(command: "psql").command, "psql")
        XCTAssertEqual(LearningPause.altScreen.logKind, "altScreen")
        XCTAssertNil(LearningPause.altScreen.command)
    }
}
