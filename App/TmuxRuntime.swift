// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import NeotildeKit
import NeotildeSSHCoreFFI

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

    /// Per-pane foreground-process context (context-detection spec). Updated by the
    /// ~1 Hz `list-panes` poll; the keybar (Phase 4) is the only future consumer.
    private var contextStore = PaneContextStore(
        knownProcesses: PromotionRegistry.bundledDefault.knownProcesses)
    /// Fired after a poll changed any pane's engaged context.
    var onContextsChanged: (() -> Void)?
    /// In-flight context-poll submission ids awaiting their result block.
    private var contextPollIDs: Set<UInt64> = []
    /// The repeating poll task; cancelled on teardown via `stop()`.
    private var pollTask: Task<Void, Never>?

    init(sessionName: String) { self.sessionName = sessionName }

    /// The current structural state (windows, layouts, active window/pane).
    var state: TmuxSessionState { controller.state }

    /// The controller's lifecycle, read when the channel closes to tell a clean
    /// `%exit` from a crash (degraded-mode spec).
    var lifecycle: TmuxLifecycle { controller.lifecycle }

    /// The `tmux -CC new-session -A -s <name>` command to run via `open_exec`.
    func makeStartCommand() -> String? { controller.start(sessionName: sessionName) }

    /// Feed raw channel bytes: fan pane output out by id, then publish state.
    func ingest(_ bytes: [UInt8]) {
        let out = controller.feed(bytes)
        for chunk in out.paneOutput { onPaneBytes?(chunk.pane, chunk.data) }
        if out.stateChanged { onStateChanged?(controller.state) }
        for resolved in out.resolved where contextPollIDs.remove(resolved.id) != nil {
            if case .ok(let lines) = resolved.outcome {
                let now = ProcessInfo.processInfo.systemUptime
                if !contextStore.observe(parsePaneCommandListing(lines), at: now).isEmpty {
                    onContextsChanged?()
                }
            }
        }
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

    /// Toggle zoom on the active pane (tmux emits the layout change).
    func zoomActivePane() {
        guard let pane = activePane else { return }
        write(TmuxCommand.zoomPane(target: pane))
    }

    /// Open a new tmux window (Phase 4e `⌘T`).
    func newWindow() {
        write(TmuxCommand.newWindow())
    }

    /// Kill the active window (Phase 4e `⌘W`). No-op until a window exists.
    func closeActiveWindow() {
        guard let win = controller.state.activeWindow else { return }
        write(TmuxCommand.killWindow(target: win))
    }

    /// Split the active pane; `direction` names the resulting divider (Phase 4e
    /// `⌘D`/`⌘|` side-by-side, `⇧⌘D`/`⌘-` stacked).
    func splitActivePane(direction: SplitDirection) {
        guard let pane = activePane else { return }
        write(TmuxCommand.splitWindow(target: pane, direction: direction))
    }

    /// Move to the next/previous pane in the active window (Phase 4e `⌘[`/`⌘]`).
    func selectPaneRelative(next: Bool) {
        write(TmuxCommand.selectPaneRelative(next: next))
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

    /// Submit a command and return its correlation id (nil unless attached).
    private func writeTracked(_ line: String) -> UInt64? {
        guard let sub = controller.submit(line), let writer else { return nil }
        writer.enqueue(sub.wire)
        return sub.id
    }

    /// Begin polling `pane_current_command` once control mode is attached.
    func startContextPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let id = self.writeTracked(TmuxCommand.listPaneCommands()) {
                    self.contextPollIDs.insert(id)
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)   // ~1 Hz
            }
        }
    }

    /// Stop polling and release the channel (called on teardown).
    func stop() {
        pollTask?.cancel(); pollTask = nil
        writer?.finish(); writer = nil
    }

    /// The engaged context for `pane`, or nil.
    func paneContext(_ pane: PaneID) -> String? { contextStore.context(for: pane) }

    /// The active pane of the active window (nil until the first layout/window event).
    private var activePane: PaneID? {
        guard let win = controller.state.activeWindow else { return nil }
        return controller.state.window(win)?.activePane
    }
}
