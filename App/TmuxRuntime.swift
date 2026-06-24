// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import GlymrKit
import GlymrSSHCoreFFI

/// Drives a tmux control-mode session in the app: feeds inbound channel bytes to
/// the pure `TmuxSessionController`, fans every pane's output out by `PaneID`,
/// publishes structural state for the renderer, and encodes input/commands.
@MainActor
final class TmuxRuntime {
    private let controller = TmuxSessionController()
    private let sessionName: String

    /// The live control-mode channel; assigned after `open_exec`. Setting it
    /// (re)builds the serial writer so command bytes are emitted in FIFO order.
    var session: ShellSession? {
        didSet {
            writer?.finish()
            writer = session.map { SerialByteWriter(sink: ShellSessionSink(session: $0)) }
        }
    }

    /// Serializes channel writes; nil until `session` is assigned.
    private var writer: SerialByteWriter?

    /// Output bytes for a specific pane, keyed by `PaneID`. Fires for every chunk.
    var onPaneBytes: ((PaneID, [UInt8]) -> Void)?
    /// Fired after any `feed` that changed structural state (windows/layout/active).
    var onStateChanged: ((TmuxSessionState) -> Void)?
    /// Fired when control mode ends; carries the exit reason if any.
    var onExit: ((String?) -> Void)?

    init(sessionName: String) { self.sessionName = sessionName }

    /// The current structural state (windows, layouts, active window/pane).
    var state: TmuxSessionState { controller.state }

    /// The `tmux -CC new-session -A -s <name>` command to run via `open_exec`.
    func makeStartCommand() -> String? { controller.start(sessionName: sessionName) }

    /// Feed raw channel bytes: fan pane output out by id, then publish state.
    func ingest(_ bytes: [UInt8]) {
        let out = controller.feed(bytes)
        for chunk in out.paneOutput { onPaneBytes?(chunk.pane, chunk.data) }
        if out.stateChanged { onStateChanged?(controller.state) }
        if out.lifecycleChanged, case .exited(let reason) = controller.lifecycle { onExit?(reason) }
    }

    /// Encode keystrokes as `send-keys` to the active pane and write to the channel.
    func sendInput(_ bytes: [UInt8]) {
        guard let pane = activePane,
              let line = TmuxCommand.sendKeys(target: pane, bytes: bytes) else { return }
        write(line)
    }

    /// Make `id` the active window (tmux will emit the layout/active events).
    func selectWindow(_ id: WindowID) {
        write(TmuxCommand.selectWindow(target: id))
    }

    /// Tell tmux the client size in cells so it re-tiles; ignored if degenerate.
    func setClientSize(cols: Int, rows: Int) {
        guard let line = TmuxCommand.refreshClientSize(width: cols, height: rows) else { return }
        write(line)
    }

    /// Submit a command line and enqueue its framed bytes for ordered writing.
    private func write(_ line: String) {
        guard let sub = controller.submit(line), let writer else { return }
        writer.enqueue(sub.wire)
    }

    /// The active pane of the active window (nil until the first layout/window event).
    private var activePane: PaneID? {
        guard let win = controller.state.activeWindow else { return nil }
        return controller.state.window(win)?.activePane
    }
}
