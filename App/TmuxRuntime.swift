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
    /// Last cols we told tmux via `refresh-client` — echoed into the `.sizing` output
    /// probe so a single log line pairs the reported width with the observed line width.
    private var lastReportedCols = 0
    /// In-flight context-poll submission ids awaiting their result block.
    private var contextPollIDs: Set<UInt64> = []
    /// In-flight `list-windows` (attach-prime) submission ids awaiting their reply.
    private var primeWindowIDs: Set<UInt64> = []
    /// In-flight `queryAlternateOn` submission ids awaiting their reply.
    private var altScreenQueryIDs: Set<UInt64> = []
    /// Purpose of an in-flight `capture-pane`. Currently only a scrollback SEED (feeds
    /// `PaneHistorySeeder` via `onHistoryCaptured`); the window-transition SNAPSHOT purpose
    /// was removed with the drop-snapshot window-switch design (2026-07-19). Kept as an enum
    /// so the capture-reply routing stays explicit if another purpose is added.
    private enum CapturePurpose { case seed }
    /// Correlation ids for in-flight `capture-pane` requests, keyed to (pane, purpose).
    private var captureIDs: [UInt64: (pane: PaneID, purpose: CapturePurpose)] = [:]
    /// Fired when a capture response resolves: (pane, reconstructed history bytes).
    var onHistoryCaptured: ((PaneID, [UInt8]) -> Void)?
    /// Fired when a pane's history may be stale (%pause/%continue, reconnect, resize
    /// desync) — the seeder should mark affected panes unseeded and re-capture.
    var onResyncAll: (() -> Void)?
    /// Called once per pane at attach with tmux's `#{alternate_on}` truth, so the
    /// mode tracker can reconcile a pane that was already on the alternate screen
    /// before this -CC client attached (device trace 2026-07-14).
    var onAltScreenReconcile: ((PaneID, Bool) -> Void)?
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
        DebugLog.shared.log(.tmux, {
            let preview = String(decoding: bytes.prefix(80).map { (0x20...0x7e).contains($0) ? $0 : 0x2e }, as: UTF8.self)
            return "tmux rx[\(bytes.count)B] paneOut=\(out.paneOutput.count) resolved=\(out.resolved.count): \(preview)"
        }())
        // Staircase/wrap diagnostic (`.sizing`, default-OFF). For each pane chunk,
        // measure the widest run of printable bytes between line breaks (CR/LF) — the
        // effective line width tmux is emitting. If this is ~50 while we report 80 cols
        // to tmux, the wrap is upstream (the pane/program formatted narrow); if it's ~80
        // and text still staircases on screen, the wrap is in SwiftTerm's render. We do
        // NOT log the bytes' content (privacy) — only the max/last printable run length
        // and whether the chunk carried a CSI (escape) so we can tell reflowed redraws
        // from raw program output. Gated autoclosure → zero cost when the category is off.
        DebugLog.shared.log(.sizing, {
            // Count only VISIBLE columns: skip bytes inside an ESC/CSI sequence so
            // `eza --color`'s SGR codes (`\e[38;5;..m`) don't inflate the width. A CSI
            // runs from ESC until its final byte in 0x40...0x7e (`m`, `H`, …).
            // esc: 0 = normal, 1 = just saw ESC (awaiting `[` or a 2-byte final),
            //      2 = inside a CSI body (skip until a final byte 0x40...0x7e).
            var maxRun = 0, run = 0, hasCSI = false, esc = 0
            for chunk in out.paneOutput {
                for b in chunk.data {
                    if esc == 1 {                            // byte after ESC
                        esc = (b == 0x5b) ? 2 : 0            // `[` → CSI body; else 2-byte ESC ends
                        continue
                    }
                    if esc == 2 {                            // CSI body: params/intermediates
                        if (0x40...0x7e).contains(b) { esc = 0 }   // final byte ends the CSI
                        continue
                    }
                    if b == 0x1b { hasCSI = true; esc = 1; continue }  // ESC begins a sequence
                    if b == 0x0a || b == 0x0d {              // LF / CR resets the visible run
                        if run > maxRun { maxRun = run }
                        run = 0
                    } else if (0x20...0x7e).contains(b) || b >= 0x80 {
                        // printable ASCII or a UTF-8 lead/continuation byte counts toward width
                        // (approx: multibyte glyphs slightly over-count, fine for a width probe)
                        run += 1
                    }
                }
            }
            if run > maxRun { maxRun = run }
            let panes = out.paneOutput.map { "@\($0.pane.raw)" }.joined(separator: ",")
            return "sizing:output panes=[\(panes)] maxPrintRun=\(maxRun) hasCSI=\(hasCSI) reportedCols=\(lastReportedCols)"
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
            DebugLog.shared.log(.tmux, "tmux prime: attach edge → onResyncAll")
            onResyncAll?()
        }
        for cmd in out.attachedPrimeCommands {
            if cmd == TmuxCommand.listWindowsForLayout() {
                if let id = writeTracked(cmd) { primeWindowIDs.insert(id); DebugLog.shared.log(.tmux, "tmux prime: sent list-windows (req \(id))") }
                else { DebugLog.shared.log(.tmux, "tmux prime: list-windows writeTracked returned NIL") }
            } else if cmd == TmuxCommand.queryAlternateOn() {
                if let id = writeTracked(cmd) { altScreenQueryIDs.insert(id); DebugLog.shared.log(.tmux, "tmux prime: sent alternate_on query (req \(id))") }
                else { DebugLog.shared.log(.tmux, "tmux prime: alternate_on writeTracked returned NIL") }
            } else {
                DebugLog.shared.log(.tmux, "tmux prime: sent \(cmd.prefix(40))")
                write(cmd)
            }
        }
        for resolved in out.resolved {
            if contextPollIDs.remove(resolved.id) != nil {
                if case .ok(let lines) = resolved.outcome {
                    let now = ProcessInfo.processInfo.systemUptime
                    let parsed = parsePaneCommandListing(lines)
                    // Sizing/coverage diagnostic (#B, 2026-07-16): the alt-scroll decider
                    // reads paneContexts[pane] for the DRAGGED pane; a device trace showed
                    // the dragged pane (e.g. %16 in a non-@0 window) was ABSENT from this
                    // reply, so paneCommand was nil -> arrows. Log the FULL parsed pane set
                    // (not the 80-char rx preview) so the next trace shows exactly which
                    // panes `list-panes -a` returns vs. which pane the drag targets.
                    DebugLog.shared.log(.tmux,
                        "tmux context REPLY: lines=\(lines.count) panes=[\(parsed.map { "%\($0.0.raw):\($0.1)" }.joined(separator: " "))]")
                    if !contextStore.observe(parsed, at: now).isEmpty {
                        onContextsChanged?()
                    }
                }
            } else if primeWindowIDs.remove(resolved.id) != nil {
                if case .ok(let lines) = resolved.outcome {
                    let parsed = parseWindowListing(lines)
                    let events = windowListingEvents(parsed,
                                                     sessionID: controller.state.sessionID ?? SessionID(raw: 0))
                    let applied = controller.applyEvents(events)
                    DebugLog.shared.log(.tmux, "tmux prime REPLY: lines=\(lines.count) parsedWindows=\(parsed.count) events=\(events.count) applied=\(applied) → wins now \(controller.state.windows.count)")
                    if applied { onStateChanged?(controller.state) }
                } else {
                    DebugLog.shared.log(.tmux, "tmux prime REPLY: NOT .ok (list-windows errored)")
                }
            } else if altScreenQueryIDs.remove(resolved.id) != nil {
                if case .ok(let lines) = resolved.outcome {
                    let entries = parseAlternateOnListing(lines)
                    DebugLog.shared.log(.tmux, "tmux alternate_on REPLY: panes=\(entries.count) alt=\(entries.filter { $0.isAlt }.map { "%\($0.pane.raw)" }.joined(separator: ","))")
                    for e in entries { onAltScreenReconcile?(e.pane, e.isAlt) }
                } else {
                    DebugLog.shared.log(.tmux, "tmux alternate_on REPLY: NOT .ok")
                }
            } else if let entry = captureIDs.removeValue(forKey: resolved.id) {
                let bytes: [UInt8]
                if case .ok(let lines) = resolved.outcome {
                    bytes = reconstructHistory(fromLines: lines)
                    DebugLog.shared.log(.tmux, "tmux capture REPLY: pane=%\(entry.pane.raw) purpose=\(entry.purpose) lines=\(lines.count) bytes=\(bytes.count)")
                } else {
                    bytes = []
                    DebugLog.shared.log(.tmux, "tmux capture REPLY: pane=%\(entry.pane.raw) purpose=\(entry.purpose) NOT .ok (capture errored)")
                }
                switch entry.purpose {
                case .seed: onHistoryCaptured?(entry.pane, bytes)   // seed fails toward live-only ([])
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
            DebugLog.shared.log(.tmux, "sendInput: NO activePane — dropping \(bytes.count)B")
            return
        }
        guard let line = TmuxCommand.sendKeys(target: pane, bytes: bytes) else { return }
        write(line)
        DebugLog.shared.log(.tmux, "send-keys → \(line)")   // after write; @autoclosure no-op when disabled
    }

    /// Make `id` the active window (tmux will emit the layout/active events).
    func selectWindow(_ id: WindowID) {
        DebugLog.shared.log(.tmux, "tmux:send select-window target=@\(id.raw)")
        write(TmuxCommand.selectWindow(target: id))
    }

    /// Toggle zoom on the active pane (tmux emits the layout change).
    func zoomActivePane() {
        guard let pane = activePane else { return }
        DebugLog.shared.log(.tmux, "tmux:send zoom-pane target=%\(pane.raw)")
        write(TmuxCommand.zoomPane(target: pane))
    }

    /// Open a new tmux window (Phase 4e `⌘T`).
    func newWindow() {
        DebugLog.shared.log(.tmux, "tmux:send new-window")
        write(TmuxCommand.newWindow())
    }

    /// Kill the active window (Phase 4e `⌘W`). No-op until a window exists.
    func closeActiveWindow() {
        guard let win = controller.state.activeWindow else { return }
        DebugLog.shared.log(.tmux, "tmux:send kill-window target=@\(win.raw)")
        write(TmuxCommand.killWindow(target: win))
    }

    /// Split the active pane; `direction` names the resulting divider (Phase 4e
    /// `⌘D`/`⌘|` side-by-side, `⇧⌘D`/`⌘-` stacked).
    func splitActivePane(direction: SplitDirection) {
        guard let pane = activePane else { return }
        DebugLog.shared.log(.tmux, "tmux:send split-window target=%\(pane.raw) direction=\(direction)")
        write(TmuxCommand.splitWindow(target: pane, direction: direction))
    }

    /// Move to the next/previous pane in the active window (Phase 4e `⌘[`/`⌘]`).
    func selectPaneRelative(next: Bool) {
        DebugLog.shared.log(.tmux, "tmux:send select-pane next=\(next)")
        write(TmuxCommand.selectPaneRelative(next: next))
    }

    /// Tell tmux the client size in cells so it re-tiles; ignored if degenerate.
    func setClientSize(cols: Int, rows: Int) {
        guard let line = TmuxCommand.refreshClientSize(width: cols, height: rows) else { return }
        lastReportedCols = cols
        DebugLog.shared.log(.tmux, "tmux:send refresh-client size=\(cols)x\(rows)")
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
        captureIDs[id] = (pane, .seed)
        DebugLog.shared.log(.tmux, "tmux capture: pane=%\(pane.raw) purpose=seed lines=\(lines) id=\(id)")
        return id
    }

    /// Re-issue the `#{alternate_on}` query (the attach-prime one) on demand, tracking its
    /// reply through the same `altScreenQueryIDs` → `onAltScreenReconcile` path. Called when
    /// the pane container re-creates panes after a tmux window-switch: switching away
    /// `forget()`s the off-screen pane's tracked alt-state, and window-return re-creates the
    /// pane with no fresh alt-state, so it fell through to the (unreliable, often false) live
    /// emulator flag and a Claude/vim pane misclassified as `.mouseReporting` -> the drag
    /// became a stuck SwiftTerm selection (device trace 2026-07-16, Bug 2). Re-querying tmux
    /// re-seeds the authoritative flag, and is correct even if the pane genuinely left the
    /// alternate screen while off-screen. No-op / nil if not attached.
    @discardableResult
    func requeryAlternateOn() -> UInt64? {
        guard let id = writeTracked(TmuxCommand.queryAlternateOn()) else {
            DebugLog.shared.log(.tmux, "tmux requery alternate_on: writeTracked NIL (not attached)")
            return nil
        }
        altScreenQueryIDs.insert(id)
        DebugLog.shared.log(.tmux, "tmux requery: sent alternate_on query (req \(id))")
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

    /// The pane's RAW `pane_current_command` (un-debounced, un-gated): what the alt-scroll
    /// decider reads. `paneContext` returns the keybar-gated `engagedContext`, which is nil
    /// for non-keybar apps like claude (Bug 1, 2026-07-16); this reports any command.
    func paneRawCommand(_ pane: PaneID) -> String? { contextStore.rawContext(for: pane) }

    /// The active pane of the active window (nil until the first layout/window event).
    private var activePane: PaneID? {
        guard let win = controller.state.activeWindow else { return nil }
        return controller.state.window(win)?.activePane
    }
}
