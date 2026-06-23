// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import GlymrKit
import GlymrSSHCoreFFI

/// Drives a tmux control-mode session in the app: feeds inbound channel bytes to
/// the pure `TmuxSessionController`, forwards the active pane's output to the
/// terminal view, and encodes keystrokes as `send-keys` to the active pane.
/// Single-pane for Plan A — multi-pane layout lands in Plan B.
@MainActor
final class TmuxRuntime {
    private let controller = TmuxSessionController()
    private let sessionName: String

    /// The live control-mode channel; Task 5 assigns it after `open_exec`.
    var session: ShellSession?

    /// Bytes for the currently-active pane, ready to feed a terminal emulator.
    var onActivePaneBytes: (([UInt8]) -> Void)?
    /// Fired when control mode ends; carries the exit reason if any.
    var onExit: ((String?) -> Void)?

    init(sessionName: String) { self.sessionName = sessionName }

    /// The `tmux -CC new-session -A -s <name>` command to run via `open_exec`.
    func makeStartCommand() -> String? { controller.start(sessionName: sessionName) }

    /// Feed raw channel bytes from the control-mode exec.
    func ingest(_ bytes: [UInt8]) {
        let out = controller.feed(bytes)
        for chunk in out.paneOutput where chunk.pane == activePane {
            onActivePaneBytes?(chunk.data)
        }
        if out.lifecycleChanged, case .exited(let reason) = controller.lifecycle { onExit?(reason) }
    }

    /// Encode keystrokes as `send-keys` to the active pane and write to the channel.
    func sendInput(_ bytes: [UInt8]) {
        guard let pane = activePane,
              let line = TmuxCommand.sendKeys(target: pane, bytes: bytes),
              let sub = controller.submit(line),
              let session else { return }
        Task { try? await session.write(data: Data(sub.wire)) }
    }

    /// The active pane of the active window (nil until the first layout/window
    /// event arrives). tmux emits those structural events on attach before any
    /// `%output`, so real pane output is routed once the active pane is known;
    /// a chunk arriving in the same feed batch before them would be dropped.
    private var activePane: PaneID? {
        guard let win = controller.state.activeWindow else { return nil }
        return controller.state.window(win)?.activePane
    }
}
