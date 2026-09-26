// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import XCTest
@testable import SemicolynKit
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Real-tmux integration for the private gesture bindings: the app's launch command
/// installs them, and each action's exact `gestureSequence` makes tmux run its command.
///
/// An OUTER tmux runs the launch command in its pane (that pane is the INNER client's
/// terminal), and `send-keys -H` injects raw bytes in one write. Isolated per test via
/// TMUX_TMPDIR + HOME. Skips when tmux is absent, unless SEMICOLYN_REQUIRE_TMUX=1 (CI).
final class TmuxGestureBindingsIntegrationTests: XCTestCase {
    private struct TmuxRequiredButMissing: Error {}
    private var dir = ""

    private static let tmuxInstalled: Bool = {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "command -v tmux >/dev/null"]
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }()

    override func setUpWithError() throws {
        guard Self.tmuxInstalled else {
            if ProcessInfo.processInfo.environment["SEMICOLYN_REQUIRE_TMUX"] == "1" {
                throw TmuxRequiredButMissing()
            }
            throw XCTSkip("tmux not installed; real-tmux integration skipped")
        }
        // Short path: tmux's socket lives under TMUX_TMPDIR and Unix socket paths cap ~108.
        dir = "/tmp/smt-" + String(UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        guard !dir.isEmpty else { return }
        _ = try? sh("tmux -L outer kill-server; tmux kill-server")
        try? FileManager.default.removeItem(atPath: dir)
    }

    // MARK: - Tests

    func testEveryActionSequenceRunsItsBoundCommand() throws {
        try launchInner()
        XCTAssertEqual(try paneCount(), 1)

        try send(.splitHorizontal)   // new pane to the RIGHT, becomes active
        try waitUntil("split-window -h") { try self.paneCount() == 2 }
        XCTAssertEqual(try inner("#{pane_top}"), "0")
        XCTAssertNotEqual(try inner("#{pane_left}"), "0")

        try send(.zoom)
        try waitUntil("zoom on") { try self.inner("#{window_zoomed_flag}") == "1" }
        try send(.zoom)
        try waitUntil("zoom off") { try self.inner("#{window_zoomed_flag}") == "0" }

        XCTAssertEqual(try inner("#{pane_index}"), "1")
        try send(.cyclePane)
        try waitUntil("select-pane -t +") { try self.inner("#{pane_index}") == "0" }

        try send(.splitVertical)     // splits the left pane; new pane BELOW it, active
        try waitUntil("split-window -v") { try self.paneCount() == 3 }
        XCTAssertEqual(try inner("#{pane_left}"), "0")
        XCTAssertNotEqual(try inner("#{pane_top}"), "0")

        try send(.closePane)
        try waitUntil("kill-pane") { try self.paneCount() == 2 }

        try send(.newWindow)
        try waitUntil("new-window") { try self.windowCount() == 2 }
        XCTAssertEqual(try inner("#{window_index}"), "1")
        try send(.previousWindow)
        try waitUntil("previous-window") { try self.inner("#{window_index}") == "0" }
        try send(.nextWindow)
        try waitUntil("next-window") { try self.inner("#{window_index}") == "1" }
    }

    /// Programs write OUTPUT; only client INPUT can trigger a binding. A pane printing
    /// split's exact sequence must not split.
    func testPaneOutputOfASequenceDoesNotTriggerIt() throws {
        try launchInner()
        // `DO""NE` is typed; the shell prints `DONE`, so the marker only matches OUTPUT.
        try sh("tmux -L outer send-keys -t outer -l " + shellQuoted(#"printf '\033[9900~'; echo DO""NE"#))
        try sh("tmux -L outer send-keys -t outer Enter")
        try waitUntil("printf executed") {
            try self.sh("tmux capture-pane -p -t semicolyn").split(separator: "\n").contains("DONE")
        }
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(try paneCount(), 1)
    }

    /// The app need not start the server: a session created elsewhere (no bindings) is
    /// reused as-is and gets the bindings.
    func testReusesExistingSessionStartedWithoutBindings() throws {
        try sh("tmux -f /dev/null new-session -d -s semicolyn -n mine")
        try launchInner()
        XCTAssertEqual(try windowCount(), 1)
        XCTAssertEqual(try inner("#{window_name}"), "mine")
        try send(.splitHorizontal)
        try waitUntil("split in reused session") { try self.paneCount() == 2 }
    }

    /// A slot the user already uses is left untouched; only that one gesture backs off.
    func testUserOccupiedSlotIsLeftAloneAndOnlyThatGestureBacksOff() throws {
        try sh(#"tmux -f /dev/null new-session -d -s semicolyn \; set -s 'user-keys[900]' "$(printf '\033[1;9Z')""#)
        try launchInner()
        XCTAssertTrue(try sh("tmux show -sv 'user-keys[900]'").hasSuffix("[1;9Z"))
        XCTAssertFalse(try sh("tmux list-keys -T root User900 2>&1").contains("split-window"))

        try send(.splitHorizontal)
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(try paneCount(), 1)

        try send(.newWindow)
        try waitUntil("other gestures still bound") { try self.windowCount() == 2 }
    }

    /// Reconnect re-runs the launch against the same server: still exactly 8 bindings,
    /// same slots, still working.
    func testRelaunchKeepsExactlyEightBindings() throws {
        try launchInner()
        try sh("tmux -L outer kill-server")   // client gone; inner server + bindings stay
        try waitUntil("inner client detached") {
            try self.sh("tmux list-clients -t semicolyn 2>/dev/null") == ""
        }
        try launchInner()
        let bound = try sh("tmux list-keys -T root").split(separator: "\n").filter { $0.contains(" User9") }
        XCTAssertEqual(bound.count, 8)
        XCTAssertEqual(try sh("tmux show -sv 'user-keys[907]'"), #"\033[9907~"#)
        try send(.splitHorizontal)
        try waitUntil("split after relaunch") { try self.paneCount() == 2 }
    }

    // MARK: - Helpers

    /// Run `script` under /bin/sh with tmux isolated to `dir`. Output goes to a file, not a
    /// Pipe: a forked tmux server can inherit a pipe's write end and block a read forever.
    @discardableResult
    private func sh(_ script: String) throws -> String {
        let outPath = dir + "/out-" + UUID().uuidString
        FileManager.default.createFile(atPath: outPath, contents: nil)
        let out = try FileHandle(forWritingTo: URL(fileURLWithPath: outPath))
        defer {
            try? out.close()
            try? FileManager.default.removeItem(atPath: outPath)
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        var env = ProcessInfo.processInfo.environment
        env["TMUX_TMPDIR"] = dir
        env["HOME"] = dir
        env["LANG"] = "C.UTF-8"   // tmux refuses non-UTF-8 locales on some builds
        env.removeValue(forKey: "TMUX")
        p.environment = env
        p.standardOutput = out
        p.standardError = out
        try p.run()
        // NOT `p.waitUntilExit()`: on this toolchain (swift:6.1 on Linux) Foundation's
        // Process termination detection hangs forever once the spawned command leaves a
        // live descendant behind (exactly what `tmux ... new-session -d` does on purpose,
        // to keep the server running) -- confirmed by isolated repro against a plain
        // `sh -c "sleep 1000 & true"` with no tmux involved. A raw `waitpid` on the direct
        // child's pid is unaffected: it reaps that pid the moment it exits, regardless of
        // any grandchildren still running.
        var status: Int32 = 0
        while waitpid(p.processIdentifier, &status, 0) == -1 && errno == EINTR {}
        return try String(contentsOfFile: outPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func shellQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// Start the app's launch command as the INNER client inside an OUTER tmux pane and
    /// wait until it is attached (bindings are installed before `attach-session`).
    private func launchInner() throws {
        let launch = plainTmuxLaunchCommand(sessionName: "semicolyn")
        try sh("tmux -L outer -f /dev/null new-session -d -s outer -x 120 -y 40 "
               + shellQuoted("env -u TMUX " + launch))
        try waitUntil("inner client attached") {
            try self.sh("tmux list-clients -t semicolyn 2>/dev/null") != ""
        }
    }

    /// Write `action`'s exact gesture bytes to the inner client in ONE write.
    private func send(_ action: TmuxAction) throws {
        let hex = action.gestureSequence.map { String(format: "%02x", $0) }.joined(separator: " ")
        try sh("tmux -L outer send-keys -t outer -H " + hex)
    }

    /// Expand a tmux format against the inner session's active pane.
    private func inner(_ format: String) throws -> String {
        try sh("tmux display-message -p -t semicolyn " + shellQuoted(format))
    }

    private func paneCount() throws -> Int { Int(try inner("#{window_panes}")) ?? -1 }
    private func windowCount() throws -> Int { Int(try inner("#{session_windows}")) ?? -1 }

    /// Poll `condition` every 50ms for up to 5s; record a failure naming `what` on timeout.
    private func waitUntil(_ what: String, _ condition: () throws -> Bool) throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if try condition() { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTFail("timed out waiting for: \(what)")
    }
}
