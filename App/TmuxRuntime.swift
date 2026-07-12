// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import SemicolynKit
import SemicolynSSHCoreFFI

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

    /// DIAGNOSTIC (temporary, tmux blank-panes investigation): fired after every
    /// `ingest` with a one-line summary of what the app currently sees — lifecycle,
    /// whether an active window + visible layout exist (the guard that gates pane
    /// rendering), window/pane counts, and total bytes received. Remove once the
    /// blank-panes root cause is confirmed on device.
    var onDiagnostic: ((String) -> Void)?
    private var diagBytesTotal = 0
    /// In-flight context-poll submission ids awaiting their result block.
    private var contextPollIDs: Set<UInt64> = []
    /// In-flight `list-windows` (attach-prime) submission ids awaiting their reply.
    private var primeWindowIDs: Set<UInt64> = []
    /// Correlation ids for in-flight `capture-pane` history seeds, keyed to the pane.
    private var historyCaptureIDs: [UInt64: PaneID] = [:]
    /// Fired when a capture response resolves: (pane, reconstructed history bytes).
    var onHistoryCaptured: ((PaneID, [UInt8]) -> Void)?
    /// Fired when a pane's history may be stale (%pause/%continue, reconnect, resize
    /// desync) — the seeder should mark affected panes unseeded and re-capture.
    var onResyncAll: (() -> Void)?
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
        // Diagnostic (gated no-op when disabled): the raw preview + counts. The
        // `preview` string is built inside the autoclosure, so it costs nothing on
        // the high-frequency output path unless diagnostics is on. A `%error`/
        // `can't find pane` reply to send-keys is visible in it.
        DebugLog.shared.log({
            let preview = String(decoding: bytes.prefix(80).map { (0x20...0x7e).contains($0) ? $0 : 0x2e }, as: UTF8.self)
            return "tmux rx[\(bytes.count)B] paneOut=\(out.paneOutput.count) resolved=\(out.resolved.count): \(preview)"
        }())
        for chunk in out.paneOutput { onPaneBytes?(chunk.pane, chunk.data) }
        if out.stateChanged { onStateChanged?(controller.state) }
        // Attach-prime: on the .attaching→.attached edge the controller asks us to
        // discover the current windows (tmux emits none spontaneously on attach to
        // an existing session — the blank-panes bug). Send refresh-client (a nudge)
        // + a tracked list-windows whose reply we parse below.
        if !out.attachedPrimeCommands.isEmpty {
            // The `.attaching → .attached` edge fires exactly once per attach — first
            // connect AND every reattach/reconnect (a fresh TmuxRuntime is built each
            // time). No `%pause`/`%continue` event exists in the control-mode parser
            // yet, so this is the highest-value resync trigger reachable from here:
            // any pane history captured before this attach may now be stale.
            DebugLog.shared.log("tmux prime: attach edge → onResyncAll")
            onResyncAll?()
        }
        for cmd in out.attachedPrimeCommands {
            if cmd == TmuxCommand.listWindowsForLayout() {
                if let id = writeTracked(cmd) { primeWindowIDs.insert(id); DebugLog.shared.log("tmux prime: sent list-windows (req \(id))") }
                else { DebugLog.shared.log("tmux prime: list-windows writeTracked returned NIL") }
            } else {
                DebugLog.shared.log("tmux prime: sent \(cmd.prefix(40))")
                write(cmd)
            }
        }
        for resolved in out.resolved {
            if contextPollIDs.remove(resolved.id) != nil {
                if case .ok(let lines) = resolved.outcome {
                    let now = ProcessInfo.processInfo.systemUptime
                    if !contextStore.observe(parsePaneCommandListing(lines), at: now).isEmpty {
                        onContextsChanged?()
                    }
                }
            } else if primeWindowIDs.remove(resolved.id) != nil {
                if case .ok(let lines) = resolved.outcome {
                    let parsed = parseWindowListing(lines)
                    let events = windowListingEvents(parsed,
                                                     sessionID: controller.state.sessionID ?? SessionID(raw: 0))
                    let applied = controller.applyEvents(events)
                    DebugLog.shared.log("tmux prime REPLY: lines=\(lines.count) parsedWindows=\(parsed.count) events=\(events.count) applied=\(applied) → wins now \(controller.state.windows.count)")
                    if applied { onStateChanged?(controller.state) }
                } else {
                    DebugLog.shared.log("tmux prime REPLY: NOT .ok (list-windows errored)")
                }
            } else if let pane = historyCaptureIDs.removeValue(forKey: resolved.id) {
                if case .ok(let lines) = resolved.outcome {
                    // Reconstruct feedable bytes: join body rows + trim capture-pane's
                    // trailing blank padding (see Task 3 — confirmed vs real tmux 3.4).
                    let bytes = reconstructHistory(fromLines: lines)
                    DebugLog.shared.log("tmux capture REPLY: pane=%\(pane.raw) lines=\(lines.count) bytes=\(bytes.count)")
                    onHistoryCaptured?(pane, bytes)
                } else {
                    DebugLog.shared.log("tmux capture REPLY: pane=%\(pane.raw) NOT .ok (capture errored)")
                    onHistoryCaptured?(pane, [])   // fail toward live-only
                }
            }
        }
        if out.lifecycleChanged, case .exited(let reason) = controller.lifecycle { onExit?(reason) }
        emitDiagnostic(bytesReceived: bytes.count)
    }

    /// DIAGNOSTIC (temporary): publish what the renderer's guard sees right now.
    private func emitDiagnostic(bytesReceived: Int) {
        diagBytesTotal += bytesReceived
        let s = controller.state
        let life: String
        switch controller.lifecycle {
        case .idle: life = "idle"
        case .attaching: life = "attaching"
        case .attached: life = "attached"
        case .exited: life = "exited"
        }
        let activeWin = s.activeWindow
        let win = activeWin.flatMap { s.window($0) }
        let hasLayout = win?.visibleLayout != nil
        let paneCount = win?.visibleLayout?.panes.count ?? 0
        onDiagnostic?(
            "tmux: \(life) · sess=\(s.sessionName ?? "nil") · wins=\(s.windows.count) · "
            + "active=\(activeWin.map(String.init(describing:)) ?? "nil") · "
            + "layout=\(hasLayout ? "yes" : "NO") · panes=\(paneCount) · rx=\(diagBytesTotal)B")
    }

    /// Encode keystrokes as `send-keys` to the active pane and write to the channel.
    func sendInput(_ bytes: [UInt8]) {
        guard let pane = activePane else {
            DebugLog.shared.log("sendInput: NO activePane — dropping \(bytes.count)B")
            return
        }
        guard let line = TmuxCommand.sendKeys(target: pane, bytes: bytes) else { return }
        write(line)
        DebugLog.shared.log("send-keys → \(line)")   // after write; @autoclosure no-op when disabled
    }

    /// Make `id` the active window (tmux will emit the layout/active events).
    func selectWindow(_ id: WindowID) {
        DebugLog.shared.log(.tmux, "tmux:send select-window target=@\(id.raw)")
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

    /// Send a `capture-pane` history seed for `pane` (N = scrollback setting). Tracks
    /// the correlation id so the response can be routed back. No-op / nil if seeding is
    /// disabled (lines <= 0) or not attached.
    func captureHistory(pane: PaneID, lines: Int) -> UInt64? {
        guard let cmd = capturePaneCommand(paneID: pane, lines: lines),
              let id = writeTracked(cmd) else { return nil }
        historyCaptureIDs[id] = pane
        DebugLog.shared.log("tmux capture: pane=%\(pane.raw) lines=\(lines) id=\(id)")
        return id
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
