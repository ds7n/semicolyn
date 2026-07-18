// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import SwiftTerm
import UIKit
import SemicolynKit
import SemicolynSSHCoreFFI

/// Crash-banner presentation state (degraded-mode spec). One case today.
enum CrashBannerState: Equatable { case tmuxEnded }

/// A modal the session presents in response to a hardware-keyboard Cmd-shortcut
/// (Phase 4e). The VM publishes the intent; `SessionView` shows the sheet.
enum SessionSheet: Identifiable {
    case settings, launcher, tips, hostPicker
    /// Confirm-and-connect prompt for a tapped ssh:// link (Phase-3c seam).
    case quickConnect(SSHConnectTarget)
    var id: String {
        switch self {
        case .settings: return "settings"
        case .launcher: return "launcher"
        case .tips: return "tips"
        case .hostPicker: return "hostPicker"
        case let .quickConnect(t): return "quickConnect:\(t.user ?? "")@\(t.host):\(t.port ?? 22)"
        }
    }
}

/// Drives the one MVP flow: connect → password auth → probe tmux → attach
/// control mode or degrade to a raw-PTY shell.
/// Retains the live `Connection`, `ShellSession`, and optionally `TmuxRuntime`.
@MainActor
final class ConnectionViewModel: ObservableObject, PredictorPurgeable {
    enum State: Equatable {
        case idle
        case connecting
        case shell
        case failed(String)
    }

    @Published var state: State = .idle
    @Published var pendingPrompt: HostKeyPrompt?
    /// Set by a Cmd-shortcut to ask `SessionView` to present a modal (Phase 4e).
    @Published var presentedSheet: SessionSheet?
    /// Non-nil when we fell back from control mode; consumed by Task 6 to show
    /// an amber banner explaining why tmux wasn't used.
    @Published var degraded: DegradeReason?
    /// Non-nil while attached to tmux control mode; nil in raw-PTY mode.
    @Published var tmuxState: TmuxSessionState?
    /// Last OSC 0/2 title received from the remote (sanitized). Phase-4 Esc-pill
    /// Live row reads this to display the current window title.
    @Published var terminalTitle: String?
    /// Whether OSC 52 clipboard writes are permitted for the active session.
    /// Resolved from `resolveOsc52Allow` at connect time; read by the terminal views.
    private(set) var osc52Allowed: Bool = true
    /// Per-pane engaged context (process name) for the keybar (Phase 4). Empty in
    /// raw-PTY mode. Re-derived from the runtime whenever a poll changes a pane.
    @Published private(set) var paneContexts: [PaneID: String] = [:]
    /// Predictor-strip suggestion state, split into its own observable slice so a
    /// suggestion recompute invalidates only the predictor-strip views (Plan B §B1).
    let predictorVM = PredictorViewModel()
    /// Nil when the predictor is disabled for this session (incognito).
    private var predictor: PredictorActor?
    private var tracker = InputTokenTracker()
    /// Trailing-debounce so a typing burst recomputes suggestions once, not per
    /// keystroke (Plan B).
    // 0.035 < the 40ms settle-hop delay so the folded `isDue` check clears the window
    // with margin (the refresh runs inside the 40ms echo-settle hop; a 40ms window would
    // land exactly on the threshold). Trailing-debounce intent unchanged: a newer
    // keystroke within ~35ms still defers the recompute.
    private var refreshCoalescer = SuggestionRefreshCoalescer(quietWindow: 0.035)
    private var learnedStore: LearnedStore?
    /// Write-time gate keeping typed secrets out of the learned vocabulary
    /// (`observePredictorInput`). See `PasswordEntryDetector`. Lazily wires the
    /// L1 echo oracle to the active pane's rendered grid on first access.
    private lazy var passwordDetector: PasswordEntryDetector = {
        var d = PasswordEntryDetector()
        d.setOracle(SwiftTermEchoOracle(resolveActiveView: { [weak self] in
            self?.activePaneView()
        }))
        return d
    }()
    /// Tokens committed on the current input line, buffered until the line commits
    /// so the whole line is learned or dropped as a unit per the detector verdict.
    private var pendingLineTokens: [CommittedToken] = []

    /// Bundled promotion sets (user override is a 4d concern).
    private let promotionRegistry = PromotionRegistry.bundledDefault
    /// Fn-layer state for the active pane. Published so the keybar re-renders the
    /// Fn slot and the F-key layer.
    @Published private(set) var fnState = FnState()
    private let autoFnProcesses = AutoFnCatalog.bundled

    /// The active pane's promotion set (empty when its context is unknown or
    /// there is no active pane). Drives the keybar's bronze promotion slots.
    var activePromotions: [PromotionSlot] {
        guard let win = tmuxState?.activeWindow,
              let pane = tmuxState?.window(win)?.activePane,
              let process = paneContexts[pane],
              let set = promotionRegistry.set(for: process) else { return [] }
        return set.promote
    }
    /// Set when tmux crashed mid-session and we dropped to a raw shell on the same
    /// connection. The crash banner persists until the user acts.
    @Published var crashBanner: CrashBannerState?
    /// DIAGNOSTIC (temporary, tmux blank-panes investigation): the latest one-line
    /// summary of what the tmux runtime sees on attach. Rendered as a small overlay
    /// in the connected view. Remove with the rest of the diagnostic once root-caused.
    @Published var tmuxDiag: String?
    /// PaneID → live SwiftTerm view, populated by TmuxPaneContainer as panes appear.
    private var paneViews: [PaneID: TerminalView] = [:]
    /// PaneID → its last-seen OSC 0/2 title, so the window title can follow the active
    /// pane across switches rather than being clobbered by whichever pane emits last.
    private var paneLastTitles: [PaneID: String] = [:]
    private var pendingPaneBytes: [PaneID: [UInt8]] = [:]   // bytes that arrived before the view registered
    /// Panes that currently exist in the active window's visible layout.
    /// Bytes for panes NOT in this set are dropped rather than buffered (bounds memory).
    private var renderablePanes: Set<PaneID> = []
    /// tmux's `#{alternate_on}` truth for a pane at attach, from
    /// `TmuxRuntime.onAltScreenReconcile`. May arrive before the pane's `TerminalView` exists
    /// (the query reply races pane creation), so it's held here and consumed by
    /// `TmuxPaneContainer` (the owner of `PaneModeTracker`) when the pane mounts.
    private var pendingAltScreenOverrides: [PaneID: Bool] = [:]
    /// Set by `TmuxPaneContainer` (the `PaneModeTracker` owner) so a late-arriving
    /// `onAltScreenReconcile` (reply lands AFTER this pane's TerminalView already
    /// mounted) is still applied instead of only being consumed via
    /// `takeAltScreenOverride` at creation time.
    var altScreenOverrideReady: ((PaneID, Bool, TerminalView) -> Void)?

    private var promptContinuation: CheckedContinuation<Bool, Never>?

    private var connection: Connection?
    /// Non-nil while a Mosh session is driving the terminal (mutually exclusive
    /// with `tmux`). Retained so teardown can shut the UDP loop down.
    private var moshSession: MoshSession?
    /// True once the current Mosh session has delivered its first output frame (the
    /// UDP handshake completed). Gates `onEnd`: a pre-first-frame exit falls back to
    /// SSH on the retained connection; a post-first-frame exit is a mid-session crash.
    private var moshFirstFrameSeen = false
    /// First-frame watchdog: fires an SSH fallback if the Mosh loop signals no life
    /// (no onFirstFrame, no onEnd) within the window. Cancelled by either callback.
    private var moshWatchdog: Task<Void, Never>?
    /// True once a terminal Mosh handler (the watchdog fallback OR `onEnd`) has
    /// resolved this session. Guards against the watchdog and an already-enqueued
    /// `onEnd` both running their branch (main-actor-serialized, so a flag suffices):
    /// e.g. the watchdog attaches SSH, then a queued `onEnd` would otherwise clobber
    /// it with a spurious crash banner. Reset in `teardown()` with the rest of Mosh state.
    private var moshResolved = false
    /// Set when we bootstrapped Mosh but fell back to SSH before handoff. Consumed
    /// by `SessionView` to show a one-line banner (parallels `degraded`/`crashBanner`).
    @Published var moshFallback: String?
    /// Last saved-host connect args, retained so `⇧⌘R` can reconnect (Phase 4e).
    private var lastSavedHost: Host?
    /// The resolved tmux session name for the current connection, computed once at
    /// connect time and reused by attach + the reattach/start-new banner actions.
    private var tmuxSessionNameForConnection = builtInTmuxSessionName
    private var lastPassword: String?
    private(set) var session: ShellSession?
    /// Serializes raw-PTY keystroke writes (FIFO under channel back-pressure).
    /// Only used in raw mode; tmux mode writes through `TmuxRuntime`'s own writer.
    private var rawWriter: SerialByteWriter?
    /// Non-nil while a tmux control-mode session is active.
    private var tmux: TmuxRuntime?
    /// Seeds each tmux pane's scrollback history (capture-pane) before live output.
    private var historySeeder: PaneHistorySeeder?
    /// Off-screen capture-pane snapshots of non-active windows for the finger-drag
    /// window transition.
    private(set) var snapshotStore: WindowSnapshotStore?
    /// Shared output sink; the terminal view wires `onBytes` to render into itself.
    let output = TerminalShellOutput()

    /// Routes keybar gesture events to terminal bytes. Modifier-state changes
    /// publish through the VM so the keybar's armed/locked slot visuals re-render.
    private(set) lazy var keybar: KeybarInputRouter = {
        let r = KeybarInputRouter(
            applicationCursorKeys: { [weak self] in self?.activePaneApplicationCursor() ?? false },
            send: { [weak self] bytes in self?.sendTerminalInput(bytes) })
        r.onModifierChange = { [weak self] in self?.objectWillChange.send() }
        return r
    }()

    // MARK: - Host-key prompt

    /// Show a host-key modal and suspend until the user decides. One prompt is
    /// in flight per handshake; if a stale continuation somehow remains, resolve
    /// it as rejected (the safe direction) rather than leaking its task.
    func present(_ prompt: HostKeyPrompt) async -> Bool {
        DebugLog.shared.log(.connect, "hostkey: prompt shown (\(String(describing: prompt).prefix(60)))")
        return await withCheckedContinuation { cont in
            promptContinuation?.resume(returning: false)
            promptContinuation = cont
            pendingPrompt = prompt
        }
    }

    /// Called by the view when the user taps a modal button.
    func resolvePrompt(_ trusted: Bool) {
        DebugLog.shared.log(.connect, "hostkey: prompt resolved trusted=\(trusted)")
        pendingPrompt = nil
        promptContinuation?.resume(returning: trusted)
        promptContinuation = nil
    }

    // MARK: - Input routing

    func fnTap() { fnState.tap() }
    /// Send an F-key and clear a one-shot Fn arm.
    func fnTapFKey(_ n: Int) {
        keybar.tapFKey(n)
        fnState.fireFKey()
        DebugLog.shared.log(.input, "input:fnKey n=\(n)")
    }

    /// Characters typed on the terminal keyboard (SwiftTerm delegate). Routed
    /// through the keybar router so an armed Ctrl/Alt/Shift applies to real keyboard
    /// keys (e.g. armed Ctrl + 'a' → 0x01), then flows on to `sendTerminalInput`.
    /// Unmodified input passes straight through unchanged.
    func terminalKeyboardInput(_ bytes: [UInt8]) {
        keybar.keyboardInput(bytes)
        DebugLog.shared.log(.input, "input:keyboard bytes=\(bytes.count)")
    }

    /// Route terminal keystrokes: through tmux `send-keys` when control mode is
    /// attached, else straight to the raw-PTY channel.
    func sendTerminalInput(_ bytes: [UInt8]) {
        // ── SACRED PATH ─────────────────────────────────────────────────────────
        // The transport write is the FIRST thing that happens — nothing (not even a
        // string interpolation) runs ahead of it. Do NOT add work above this block.
        let signpost = PerfSignposts.input.beginInterval("send")
        if let moshSession {
            moshSession.writeInput(Data(bytes))
        } else if let tmux {
            tmux.sendInput(bytes)
        } else {
            rawWriter?.enqueue(bytes)
        }
        PerfSignposts.input.endInterval("send", signpost)
        // ── after the write: diagnostics (gated no-op) + forked observation ───────
        // `log` is an @autoclosure that is a no-op unless diagnostics is enabled, so
        // this string is not even built in normal use.
        DebugLog.shared.log(.input, "input[\(bytes.count)B] → \(moshSession != nil ? "MOSH" : (tmux != nil ? "TMUX" : "RAW"))")
        observePredictorInput(bytes)
    }

    /// DECCKM (application-cursor-keys) state of the active pane's terminal, or
    /// false if unavailable. Best-effort SwiftTerm read (cf. the mouse-mode poll).
    private func activePaneApplicationCursor() -> Bool {
        guard let win = tmuxState?.activeWindow,
              let pane = tmuxState?.window(win)?.activePane,
              let tv = paneViews[pane] else { return false }
        return tv.getTerminal().applicationCursor
    }

    /// The `TerminalView` the user is currently typing into: the tmux active
    /// pane, or — in a raw (non-tmux) session — the single registered pane.
    /// Nil until a pane is registered. Used by the L1 echo oracle.
    private func activePaneView() -> TerminalView? {
        if let win = tmuxState?.activeWindow,
           let pane = tmuxState?.window(win)?.activePane,
           let tv = paneViews[pane] {
            return tv
        }
        // Raw session: exactly one pane view once registered.
        return paneViews.count == 1 ? paneViews.first?.value : nil
    }

    // MARK: - Pane registry + tmux commands

    /// Called by TmuxPaneContainer when a pane's view is created. Seeds history for
    /// the pane, then flushes any bytes that arrived before the view existed —
    /// THROUGH the seeder, so that pre-view output is buffered by `PaneSeedState`
    /// (it's `.seeding` after `paneDidAppear`) and replayed AFTER the captured
    /// history, preserving the history-before-live-output ordering. Feeding the
    /// pending bytes directly here would race the async capture and land live output
    /// on-screen before history (then an out-of-order scrollback-clear).
    func registerPane(_ pane: PaneID, _ view: TerminalView) {
        paneViews[pane] = view
        historySeeder?.paneDidAppear(pane)
        if let buffered = pendingPaneBytes[pane] {
            pendingPaneBytes[pane] = nil
            let toFeed = historySeeder?.routeOutput(pane, buffered) ?? buffered
            if !toFeed.isEmpty { view.feed(byteArray: toFeed[...]) }
        }
        DebugLog.shared.log(.seed, "scroll:postseed pane=%\(pane.raw) contentSize=\(view.contentSize)")
    }

    func unregisterPane(_ pane: PaneID) {
        paneViews[pane] = nil
        pendingPaneBytes[pane] = nil
        paneLastTitles[pane] = nil
        pendingAltScreenOverrides[pane] = nil
    }

    /// The attach-time `#{alternate_on}` truth queued for `pane` (if the query reply
    /// arrived before or after this pane mounted), consumed once by
    /// `TmuxPaneContainer` right after it creates the pane's `TerminalView`.
    func takeAltScreenOverride(for pane: PaneID) -> Bool? {
        pendingAltScreenOverrides.removeValue(forKey: pane)
    }

    /// Publish an OSC 0/2 title from a tmux pane, keyed to the active pane: cache it
    /// per-pane and only surface the *active* pane's title so a background pane can't
    /// clobber what the user is looking at (`titleToPublish`).
    func setTmuxTitle(from view: TerminalView, _ title: String) {
        guard let pane = paneViews.first(where: { $0.value === view })?.key else { return }
        paneLastTitles[pane] = title
        let active = tmuxState?.activeWindow.flatMap { tmuxState?.window($0)?.activePane }
        if let published = titleToPublish(source: pane, active: active, title: title) {
            terminalTitle = published
        }
    }

    func selectWindow(_ id: WindowID) {
        DebugLog.shared.log(.tmux, "tmux:selectWindow id=@\(id.raw) activeBefore=\(tmuxState?.activeWindow.map { "@\($0.raw)" } ?? "nil")")
        tmux?.selectWindow(id)
    }

    /// Toggle zoom on the active pane (Pad tap). No-op in raw-PTY mode.
    func zoomActivePane() { tmux?.zoomActivePane() }

    /// Esc-pill swipe-right: next tmux window (wraps). No-op with <2 windows.
    func selectNextWindow() { stepWindow(+1) }
    /// Esc-pill swipe-left: previous tmux window (wraps).
    func selectPrevWindow() { stepWindow(-1) }

    private func stepWindow(_ delta: Int) {
        guard let state = tmuxState,
              let active = state.activeWindow,
              let idx = state.windows.firstIndex(where: { $0.id == active }),
              let next = stepIndex(current: idx, delta: delta, count: state.windows.count)
        else { return }
        selectWindow(state.windows[next].id)
    }

    /// Finger-drag window-switch commit: step one window WITH WRAP (matches the drag
    /// reveal's `neighborWindow(of:delta:)`, which wraps). No-op with <2 windows or in
    /// raw-PTY mode. Replaces the old clamped one-shot swipe commit (which disagreed
    /// with the wrapping reveal, causing an edge-commit no-op + bounce-back).
    func selectAdjacentWindowWrapping(_ delta: Int) { stepWindow(delta) }

    /// True when the active tmux session has more than one window (drives horizontal
    /// drag = window switch vs. scroll fall-through).
    var isMultiWindowTmux: Bool { (tmuxState?.windows.count ?? 0) > 1 }

    /// The window `delta` steps from `id` in window-list order, wrapping at the ends.
    /// nil with fewer than 2 windows. Matches the wrap the esc-pill switch uses.
    func neighborWindow(of id: WindowID, delta: Int) -> WindowID? {
        guard let windows = tmuxState?.windows, windows.count > 1,
              let idx = windows.firstIndex(where: { $0.id == id }) else { return nil }
        let n = windows.count
        let next = ((idx + delta) % n + n) % n
        return windows[next].id
    }

    /// Whether the in-progress input line looks like a password/secret entry, per
    /// `passwordDetector`'s verdict (used ONLY to gate diagnostic key-content logging —
    /// see `TerminalScreen.Coordinator.send`; has no effect on predictor learning, which
    /// reads the detector directly).
    func currentLineIsPassword() -> Bool { !passwordDetector.shouldLearnCommittedLine() }

    /// Single-tap cursor placement inside a tmux pane: emit arrow keys from the pane's
    /// current cursor to the tapped cell (reuses the pure encoders). Routes through the
    /// active pane's tmux send path (`sendTerminalInput`, which dispatches to
    /// `TmuxRuntime.sendInput` while `tmux` is set).
    func placeTmuxCursor(_ view: TerminalView, toCol: Int, toRow: Int) {
        let term = view.getTerminal()
        let cur = term.getCursorLocation()   // .x = col, .y = row
        let appCursor = term.applicationCursor
        let runs = cursorTapArrows(fromCol: cur.x, fromRow: cur.y, toCol: toCol, toRow: toRow)
        var bytes: [UInt8] = []
        for run in runs { bytes += encodeArrowRun(run, applicationCursorKeys: appCursor) }
        guard !bytes.isEmpty else { return }
        sendTerminalInput(bytes)
    }

    // MARK: - Hardware-keyboard commands (Phase 4e)

    /// Dispatches a resolved hardware-keyboard command to its action. Window/pane
    /// commands no-op in raw-PTY mode (no `tmux`); presentation commands publish a
    /// `presentedSheet` intent for `SessionView`.
    func perform(_ command: KeyboardCommand) {
        DebugLog.shared.log(.input, "input:command \(command)")
        switch command {
        case .newWindow:           tmux?.newWindow()
        case .closeWindow:         tmux?.closeActiveWindow()
        case .switchWindow(let n): switchToWindow(index: n)
        case .prevWindow:          selectPrevWindow()
        case .nextWindow:          selectNextWindow()
        case .prevPane:            tmux?.selectPaneRelative(next: false)
        case .nextPane:            tmux?.selectPaneRelative(next: true)
        case .splitVertical:       tmux?.splitActivePane(direction: .sideBySide)
        case .splitHorizontal:     tmux?.splitActivePane(direction: .stacked)
        case .clearScreen:         sendTerminalInput([0x0c])              // Ctrl-L
        case .paste:               pasteFromClipboard()
        case .reconnect:           reconnect()
        case .newConnection:       presentedSheet = .hostPicker
        case .openLauncher:        presentedSheet = .launcher
        case .settings:            presentedSheet = .settings
        case .tips:                presentedSheet = .tips
        case .copy:                break   // SwiftTerm handles ⌘C natively on the hardware path
        }
    }

    /// Switch to the 1-based Nth tmux window (`⌘1…⌘9`); out-of-range is a no-op.
    private func switchToWindow(index: Int) {
        guard let windows = tmuxState?.windows, index >= 1, index <= windows.count else { return }
        selectWindow(windows[index - 1].id)
    }

    /// Paste the system clipboard's text into the terminal (`⌘V`, hardware path).
    private func pasteFromClipboard() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        sendTerminalInput(Array(text.utf8))
    }

    /// Re-run the last saved-host connect (`⇧⌘R`). No-op if nothing connected yet.
    func reconnect() {
        guard let host = lastSavedHost else {
            DebugLog.shared.log(.connect, "reconnect: ABORT no lastSavedHost")
            return
        }
        DebugLog.shared.log(.connect, "reconnect: triggered for \(host.hostName)")
        connect(savedHost: host, password: lastPassword ?? "")
    }

    /// Push the tmux client size so it re-tiles. The grid is computed accurately by
    /// `TmuxPaneContainer` (container bounds ÷ measured cell), debounced there.
    func setTmuxClientSize(cols: Int, rows: Int) { tmux?.setClientSize(cols: cols, rows: rows) }

    /// The RAW foreground command for `pane` from the tmux context poll (the pane's
    /// `pane_current_command`), read from the runtime's COMPLETE map. Used by the
    /// alt-scroll decider for the pane under the finger. This reads the raw current
    /// command, NOT the keybar's debounced/known-only `engagedContext`: the latter is
    /// gated to the keybar's promotion apps (vim/less/python/…), which EXCLUDE
    /// claude/gemini/codex/qwen, so it returned nil for a Claude pane and the drag fell
    /// back to arrows instead of PgUp/PgDn (device trace 2026-07-16, Bug 1). The raw
    /// command is also un-debounced, so a drag works the instant the first poll lands.
    func tmuxPaneCommand(_ pane: PaneID) -> String? { tmux?.paneRawCommand(pane) }

    /// Re-query tmux's `#{alternate_on}` for all panes. Called by the pane container when a
    /// window-switch/reattach re-creates panes, so each fresh pane's tracked alt-screen state
    /// is re-seeded authoritatively (via `onAltScreenReconcile`) instead of the unreliable
    /// live emulator flag (Bug 2, 2026-07-16). No-op if not attached.
    func requeryAltScreenState() { tmux?.requeryAlternateOn() }

    // MARK: - Teardown

    /// User-initiated disconnect (the connected-state Disconnect button). Tears the
    /// session down and flips `state` to `.idle` so the view can dismiss back to the
    /// host list. Flushes the predictor first (teardown already does), so learning
    /// survives an explicit disconnect just like a backgrounded one.
    func disconnect() {
        DebugLog.shared.log(.lifecycle, "disconnect: user-initiated teardown → .idle")
        teardown()
        state = .idle
    }

    /// Reset all connection and pane state. Call at the start of each connect
    /// attempt so no stale handles or buffered bytes carry over to the new session.
    private func teardown() {
        moshWatchdog?.cancel(); moshWatchdog = nil
        moshResolved = false
        moshSession?.stop()
        moshSession = nil
        moshFirstFrameSeen = false
        moshFallback = nil
        tmux?.stop()
        tmux = nil
        paneContexts = [:]
        fnState.reset()
        rawWriter?.finish()
        rawWriter = nil
        session = nil
        connection = nil
        tmuxState = nil
        crashBanner = nil
        paneViews.removeAll()
        pendingPaneBytes.removeAll()
        renderablePanes.removeAll()
        flushPredictor()
        // Drop the render + harvest closures so late bytes from the old session
        // can't feed a torn-down terminal view or a cleared predictor. Both are
        // re-installed when the next shell opens.
        output.onBytes = nil
        output.onHarvestBytes = nil
        predictor = nil
        // Deregister from the active-purge slot (the VM may be reused on reconnect
        // without deallocating, so the weak ref alone isn't enough).
        if AppStores.shared.activePredictorSession === self {
            AppStores.shared.activePredictorSession = nil
        }
        tracker.reset()
        passwordDetector.reset()          // clear echo/prompt state across sessions
        pendingLineTokens.removeAll()     // drop any un-flushed line tokens
        predictorVM.setSuggestions([])
    }

    // MARK: - Auth

    /// Authenticate `conn` for `host`: if the host references a stored identity
    /// whose private key is available, use publickey; otherwise fall back to the
    /// supplied password. Returns the outcome; the caller maps non-success to a
    /// `.failed` state.
    ///
    /// Publickey-present-but-rejected is NOT silently promoted to password auth —
    /// the outcome is returned as-is (matches the cert-auth no-fallback rule).
    private func authenticate(conn: Connection, user: String, host: Host,
                              defaults: Defaults, password: String) async throws -> AuthOutcome {
        // Resolve the identity through Defaults inheritance, not just the host's explicit value.
        if let identityID = resolveIdentities(host: host, defaults: defaults).first {
            // A genuine Keychain read failure must surface (no `try?`); only a truly
            // absent private key falls back to password (e.g. SE-flavor identity whose
            // key isn't stored on this device).
            if let key = try AppStores.shared.identities.privateKeyOpenSSH(for: identityID) {
                // No silent fallback: a present-but-rejected key returns its outcome.
                DebugLog.shared.log(.connect, "authenticate: publickey (identity=\(identityID))")
                let outcome = try await conn.authenticatePublickey(user: user, privateKeyOpenssh: key)
                DebugLog.shared.log(.connect, "authenticate: publickey → \(String(describing: outcome))")
                return outcome
            }
            DebugLog.shared.log(.connect, "authenticate: identity \(identityID) has no stored key → password fallback")
        } else {
            DebugLog.shared.log(.connect, "authenticate: no identity resolved → password")
        }
        let outcome = try await conn.authenticatePassword(user: user, password: password)
        DebugLog.shared.log(.connect, "authenticate: password → \(String(describing: outcome))")
        return outcome
    }

    // MARK: - Host record

    /// Find an existing saved host matching (hostName, user) or create + persist one.
    private func findOrCreateHost(hostName: String, port: Int, user: String) throws -> Host {
        let existing = try AppStores.shared.hosts.allHosts()
            .first { $0.hostName == hostName && ($0.port.value ?? 22) == port && $0.user.value == user }
        if let existing { return existing }
        let host = Host(id: UUID(), label: hostName, hostName: hostName,
                        user: .explicit(user), port: .explicit(port))
        try AppStores.shared.hosts.saveHost(host)
        return host
    }

    /// Present the confirm-and-connect sheet for a tapped ssh:// link. Parses the
    /// URL and silently ignores anything that isn't a usable ssh:// target — a tap
    /// never connects on its own (Phase-3c ssh:// link seam).
    func presentSSHLink(_ url: URL) {
        guard let target = parseSSHURL(url.absoluteString) else { return }
        presentedSheet = .quickConnect(target)
    }

    /// Find an existing saved host matching an ssh:// target, or create + persist one.
    /// A target without a user inherits the default user (`.inherit`).
    func hostForSSHTarget(_ target: SSHConnectTarget) throws -> Host {
        let port = target.port ?? 22
        let existing = try AppStores.shared.hosts.allHosts()
            .first { $0.hostName == target.host && ($0.port.value ?? 22) == port && $0.user.value == target.user }
        if let existing { return existing }
        let host = Host(id: UUID(), label: target.host, hostName: target.host,
                        user: target.user.map { Inherited.explicit($0) } ?? .inherit,
                        port: .explicit(port))
        try AppStores.shared.hosts.saveHost(host)
        return host
    }

    // MARK: - Shell paths

    /// Run `tmux -V` over a one-shot exec and return its stdout (nil if nothing
    /// came back or the channel failed). Resolves when the exec channel closes.
    private func probeTmuxVersion(conn: Connection) async -> String? {
        let sink = TerminalShellOutput()
        var captured: [UInt8] = []
        sink.onBytes = { captured.append(contentsOf: $0) }
        let done = AsyncStream<Void> { cont in
            sink.onExit = { _ in cont.yield(); cont.finish() }
        }
        let probeSession = try? await conn.openExec(command: "tmux -V", term: "xterm-256color",
                                                    cols: 80, rows: 24, output: sink)
        guard probeSession != nil else {
            DebugLog.shared.log(.tmux, "probeTmuxVersion: exec FAILED to open → nil")
            return nil
        }
        defer { if let probeSession { Task { try? await probeSession.close() } } }
        // Race the exec-channel close against a 2-second guard in case onExit
        // is never fired (e.g. some server implementations don't send channel EOF
        // on exec exit).
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await _ in done { break }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            await group.next()
            group.cancelAll()
        }
        let text = String(decoding: captured, as: UTF8.self)
        DebugLog.shared.log(.tmux, "probeTmuxVersion: got \(text.isEmpty ? "EMPTY (nil)" : text.trimmingCharacters(in: .whitespacesAndNewlines))")
        return text.isEmpty ? nil : text
    }

    /// Open a raw PTY shell: the original pre-tmux path. Sets `connection`,
    /// `session`, and `state = .shell`.
    private func openRawShell(conn: Connection) async throws {
        DebugLog.shared.log(.lifecycle, "openRawShell: opening PTY shell")
        let sess = try await conn.openShell(
            term: "xterm-256color", cols: 80, rows: 24, output: output)
        connection = conn
        session = sess
        rawWriter = SerialByteWriter(sink: ShellSessionSink(session: sess))
        tmuxState = nil   // raw mode: single-terminal path
        output.onHarvestBytes = { [weak self] bytes in
            guard let self else { return }
            // Feed output to the password-prompt gate only. We deliberately no longer
            // harvest free terminal output as suggestion candidates — that pulled the
            // shell prompt (Starship) into suggestions. Suggestions now source from
            // typed-command echo (record) + seed only. (predictor-suggestion-hygiene spec, Fix 1.)
            self.passwordDetector.noteOutput(bytes)
        }
        DebugLog.shared.log(.lifecycle, "openRawShell: shell opened, state=.shell")
        state = .shell
    }

    /// Probe tmux on the authenticated connection and attach the tmux control-mode
    /// session or fall back to a degraded raw shell. This is the shared SSH tail of
    /// both `connect` methods, factored out so the Mosh pre-frame fallback can re-run
    /// it on the SAME retained connection (see `attachMoshIfPossible`).
    private func attachSSHShell(conn: Connection, host: Host, defaults: Defaults) async throws {
        let allow = resolveTmuxAttemptControlMode(host: host, defaults: defaults)
        let probe = allow ? await probeTmuxVersion(conn: conn) : nil
        DebugLog.shared.log(.lifecycle, "attachSSHShell: allowControlMode=\(allow) probe=\(probe ?? "nil")")
        switch tmuxLaunchDecision(attemptControlMode: allow, versionProbe: probe) {
        case .attach:
            DebugLog.shared.log(.lifecycle, "attachSSHShell: decision=ATTACH tmux")
            self.tmuxSessionNameForConnection = resolveTmuxSessionName(host: host, defaults: defaults)
            try await attachTmux(conn: conn)
        case .degrade(let reason):
            DebugLog.shared.log(.lifecycle, "attachSSHShell: decision=DEGRADE(\(String(describing: reason))) → raw shell")
            degraded = reason
            try await openRawShell(conn: conn)
        }
    }

    // MARK: - Mosh path

    /// Run the `mosh-server` bootstrap over a one-shot exec and return its stdout
    /// (empty string if nothing came back or the channel failed). Resolves when the
    /// exec channel closes or a 2s guard fires — same race as `probeTmuxVersion`.
    private func captureMoshBootstrap(conn: Connection, command: String) async -> String {
        let sink = TerminalShellOutput()
        var captured: [UInt8] = []
        sink.onBytes = { captured.append(contentsOf: $0) }
        let done = AsyncStream<Void> { cont in
            sink.onExit = { _ in cont.yield(); cont.finish() }
        }
        let sess = try? await conn.openExec(command: command, term: "xterm-256color",
                                            cols: 80, rows: 24, output: sink)
        guard sess != nil else {
            DebugLog.shared.log(.connect, "mosh: bootstrap exec FAILED to open (openExec returned nil)")
            return ""
        }
        defer { if let sess { Task { try? await sess.close() } } }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { for await _ in done { break } }
            group.addTask { try? await Task.sleep(nanoseconds: 2_000_000_000) }
            await group.next(); group.cancelAll()
        }
        return String(decoding: captured, as: UTF8.self)
    }

    /// Attach a Mosh session on the authenticated connection: bootstrap mosh-server,
    /// decide, and either create a `MoshSession` or fall back to the SSH/tmux path
    /// with a banner. Returns true if a Mosh session was attached; false if it fell
    /// back (the caller then runs the existing tmux/raw branch).
    private func attachMoshIfPossible(conn: Connection, host: Host, defaults: Defaults) async -> Bool {
        guard resolveMoshEnabled(host: host, defaults: defaults) else {
            DebugLog.shared.log(.connect, "mosh: disabled for this host → SSH/tmux path")
            return false
        }
        // Effective config for the argv (port range, server path, prediction mode).
        // resolveOptional honors Inherited three-state (NOT host.mosh.value).
        let cfg = resolveOptional(host.mosh, defaults.mosh) ?? MoshConfig(enabled: true)
        let command = moshServerCommand(cfg).joined(separator: " ")
        let stdout = await captureMoshBootstrap(conn: conn, command: command)
        DebugLog.shared.log(.connect, "mosh: bootstrap captured \(stdout.count)B")
        switch moshBranchOutcome(stdout: stdout, enabled: true) {
        case let .mosh(port, key):
            DebugLog.shared.log(.connect, "mosh: bootstrap OK port=\(port) keyLen=\(key.count) → starting UDP session")
            // mosh-client's getaddrinfo uses AI_NUMERICHOST (numeric IP only, NO DNS),
            // so it rejects a hostname. Resolve host.hostName to a numeric IP here
            // (SSH already reached the host, so it resolves). If we can't resolve, don't
            // hand mosh a name it will reject — fall back to SSH with a clear reason.
            guard let moshIP = MoshHostResolver.numericAddress(for: host.hostName) else {
                DebugLog.shared.log(.connect, "mosh: could not resolve \(host.hostName) to an IP → SSH fallback")
                moshFallback = "Mosh: couldn't resolve \(host.hostName) — using SSH"
                return false
            }
            DebugLog.shared.log(.connect, "mosh: resolved \(host.hostName) → \(moshIP)")
            let predict = cfg.predictionMode?.rawValue ?? "adaptive"
            // Seeded at 80×24: the terminal view hasn't laid out yet at connect time,
            // so the real grid isn't known here. The first debounced resize from
            // TerminalScreen (via setMoshClientSize) corrects it once layout happens,
            // and mosh reflows. FUTURE (item #5 Q2(b)): to skip the brief 80×24 first
            // frame, track the last-known terminal grid on the VM and pass it here.
            let sess = MoshSession(ip: moshIP, port: String(port), key: key,
                                   cols: 80, rows: 24, predictMode: predict)
            // Reset the handshake gate: onEnd before the first frame means the UDP
            // handshake never completed → fall back to SSH on the retained connection;
            // onEnd after a frame is a genuine mid-session exit → crash banner.
            moshFirstFrameSeen = false
            // Route Mosh output through the SAME buffered entry point as the Rust
            // SSH path (`output.onOutput`) rather than calling the stored `onBytes`
            // sink directly. Mosh's first framebuffer diff is emitted synchronously
            // during `sess.start()` — before `state = .shell` triggers SwiftUI's
            // `makeUIView`, which is what installs the render sink — so a direct
            // `onBytes?` call would silently drop that frame (nil sink → no-op) and
            // leave the terminal permanently blank. `onOutput` appends to the
            // `PendingOutputBuffer`, which replays on sink-install. (Harvest stays
            // off the Mosh path: `onHarvestBytes` is never installed here, so its
            // pass in `onOutput` is a no-op.)
            sess.onOutput = { [weak self] data in
                self?.output.onOutput(data: data)
            }
            sess.onFirstFrame = { [weak self] in
                // Frames are flowing: the UDP path is up. `moshFirstFrameSeen` is no
                // longer the exit discriminator (that's reason+elapsed now), but it
                // still records that a frame arrived; cancelling the watchdog here is
                // the important effect — the loop signalled life, so don't SSH-fall-back.
                DebugLog.shared.log(.connect, "mosh: onFirstFrame — UDP handshake up, frames flowing")
                self?.moshFirstFrameSeen = true
                self?.moshWatchdog?.cancel(); self?.moshWatchdog = nil
                DebugLog.shared.log(.connect, "mosh: watchdog cancelled (onFirstFrame)")
            }
            // Stamp the start time BEFORE the onEnd closure literal so the closure can
            // capture it (Swift resolves captures at declaration order, not runtime).
            // The session can't fire onEnd before sess.start() below, so this is the
            // true session-start instant. Monotonic clock (systemUptime).
            let moshStartedAt = ProcessInfo.processInfo.systemUptime
            sess.onEnd = { [weak self] reason in
                guard let self else { return }
                self.moshWatchdog?.cancel(); self.moshWatchdog = nil
                // The watchdog may have already resolved this session (attached SSH)
                // via an onEnd dispatch that was enqueued before the watchdog niled it.
                // Bail so we don't clobber the watchdog's SSH shell with a stale banner.
                if self.moshResolved {
                    DebugLog.shared.log(.connect, "mosh: onEnd after watchdog already resolved → ignored")
                    return
                }
                self.moshResolved = true
                DebugLog.shared.log(.connect, "mosh: onEnd firstFrameSeen=\(self.moshFirstFrameSeen) reason=\(reason ?? "nil")")
                let elapsed = ProcessInfo.processInfo.systemUptime - moshStartedAt
                switch moshExitDecision(reason: reason, elapsed: elapsed) {
                case .crashBanner:
                    self.moshSession?.stop()
                    self.moshSession = nil
                    self.moshFirstFrameSeen = false
                    DebugLog.shared.log(.connect, "mosh: exit crashBanner (elapsed=\(String(format: "%.2f", elapsed))s) → crash banner")
                    self.crashBanner = .tmuxEnded
                    return
                case .ended:
                    // Clean exit (rc == 0). v1: surface via the same session-ended state
                    // as a clean tmux exit (no alarming "crashed" copy needed).
                    self.moshSession?.stop()
                    self.moshSession = nil
                    self.moshFirstFrameSeen = false
                    DebugLog.shared.log(.connect, "mosh: exit ended (clean, elapsed=\(String(format: "%.2f", elapsed))s) → session ended")
                    self.crashBanner = .tmuxEnded
                    return
                case .fallbackSSH:
                    self.moshSession?.stop()
                    self.moshSession = nil
                    // Surface the REAL reason captured from mosh's stderr (e.g.
                    // "Mosh failed: Crypto: … — using SSH") when we have it; the bridge
                    // falls back to a generic string only when nothing was captured.
                    self.moshFallback = reason ?? "Mosh connection failed — using SSH"
                    DebugLog.shared.log(.connect, "mosh: exit fallbackSSH (elapsed=\(String(format: "%.2f", elapsed))s) → SSH fallback")
                    Task { [weak self] in
                        guard let self else { return }
                        do {
                            try await self.attachSSHShell(conn: conn, host: host, defaults: defaults)
                        } catch {
                            DebugLog.shared.log(.connect, "mosh: SSH fallback THREW \(String(describing: error)) → .failed")
                            self.state = .failed(String(describing: error))
                        }
                    }
                }
            }
            DebugLog.shared.log(.connect, "mosh: sess.start() — UDP session launching, state=.shell")
            sess.start()
            moshSession = sess
            connection = conn
            tmuxState = nil
            moshWatchdog = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 10_000_000_000)   // 10s watchdog window
                guard !Task.isCancelled, let self else { return }
                // No onFirstFrame/onEnd cancelled us → the loop signalled no life.
                guard case .fallbackSSH = moshWatchdogAction(sawAnyCallback: false) else { return }
                // Claim the resolution before the attachSSHShell suspension point so a
                // late onEnd (enqueued before we niled the callback) bails instead of
                // clobbering this SSH shell.
                if self.moshResolved { return }
                self.moshResolved = true
                DebugLog.shared.log(.connect, "mosh: watchdog fired (no frame/exit in 10s) → SSH fallback")
                self.moshSession?.stop()
                self.moshSession = nil
                self.moshFallback = "Mosh didn't connect — using SSH"
                do {
                    try await self.attachSSHShell(conn: conn, host: host, defaults: defaults)
                } catch {
                    DebugLog.shared.log(.connect, "mosh: watchdog SSH fallback THREW \(String(describing: error)) → .failed")
                    self.state = .failed(String(describing: error))
                }
            }
            state = .shell
            return true
        case let .fallback(reason):
            DebugLog.shared.log(.connect, "mosh: bootstrap FALLBACK (\(reason)) → caller runs SSH/tmux")
            moshFallback = reason   // pre-handoff banner; caller runs the SSH/tmux path
            return false
        }
    }

    /// Whether a Mosh session is currently driving the terminal. The view uses
    /// this to route its debounced resize to `setMoshClientSize` (Mosh has no
    /// `ShellSession`, so `TerminalScreen`'s default `session?.resize` is a no-op).
    /// Keeps the `MoshSession` object itself private.
    var isMoshActive: Bool { moshSession != nil }

    /// Push a new terminal size to the running Mosh session. No-op outside Mosh mode.
    func setMoshClientSize(cols: Int, rows: Int) { moshSession?.resizeCols(Int32(cols), rows: Int32(rows)) }

    /// Reconcile Fn auto-engage with the active pane's foreground process.
    private func refreshFnAutoEngage() {
        let process: String? = {
            guard let win = tmuxState?.activeWindow,
                  let pane = tmuxState?.window(win)?.activePane else { return nil }
            return paneContexts[pane]
        }()
        if let process, autoFnProcesses.contains(process) {
            fnState.autoEngage()
        } else {
            fnState.autoDisengage()
        }
    }

    /// Attach tmux control mode: open the `-CC` exec, pump its bytes into a
    /// `TmuxRuntime`, and route the active pane's output into the terminal view.
    private func attachTmux(conn: Connection) async throws {
        DebugLog.shared.log(.lifecycle, "attachTmux: ENTER session=\(tmuxSessionNameForConnection)")
        // Self-narrating anchor for a device trace: build + session so a pasted log
        // fragment is self-locating (paired with the per-drag decision lines).
        // No clean transport symbol is in scope here (attachTmux runs for both
        // SSH-from-start and post-mosh-fallback SSH; moshSession is already nil
        // by the time this executes), so that field is intentionally omitted.
        let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "?"
        DebugLog.shared.log(.lifecycle,
            "=== session-start build=\(build) session=\(tmuxSessionNameForConnection) ===")
        let runtime = TmuxRuntime(sessionName: tmuxSessionNameForConnection)
        let seeder = PaneHistorySeeder(
            runtime: runtime,
            scrollbackLines: { AppStores.shared.terminalSettings.settings.scrollbackLines },
            viewForPane: { [weak self] pane in self?.paneViews[pane] })
        self.historySeeder = seeder
        self.snapshotStore = WindowSnapshotStore(
            runtime: runtime,
            scrollbackLines: { AppStores.shared.terminalSettings.settings.scrollbackLines },
            makeSnapshotView: { _ in
                let v = TerminalView(frame: .zero)
                v.isUserInteractionEnabled = false   // a static preview, never interactive
                return v
            })
        guard let startCmd = runtime.makeStartCommand() else {
            // Controller couldn't build a start command (e.g. an invalid resolved
            // session name — which a Defaults-level value can be, since the Defaults
            // editor has no per-field validation). Surface it via the degraded
            // banner instead of silently dropping to a raw shell everywhere.
            DebugLog.shared.log(.lifecycle, "attachTmux: makeStartCommand nil (bad session name) → degraded raw shell")
            degraded = .couldNotStart
            try await openRawShell(conn: conn)
            return
        }
        runtime.onPaneBytes = { [weak self] pane, bytes in
            guard let self else { return }
            if let view = self.paneViews[pane] {
                let toFeed = self.historySeeder?.routeOutput(pane, bytes) ?? bytes
                if !toFeed.isEmpty { view.feed(byteArray: toFeed[...]) }
            } else if self.renderablePanes.contains(pane) {
                self.pendingPaneBytes[pane, default: []].append(contentsOf: bytes)
            } else {
                // Pane not in the visible layout — drop to prevent unbounded
                // buffering, and don't harvest output the user can't see.
                return
            }
            // Feed output to the password-prompt gate only. We deliberately no longer
            // harvest free terminal output as suggestion candidates — that pulled the
            // shell prompt (Starship) into suggestions. Suggestions now source from
            // typed-command echo (record) + seed only. (predictor-suggestion-hygiene spec, Fix 1.)
            self.passwordDetector.noteOutput(bytes)
        }
        runtime.onStateChanged = { [weak self] state in
            guard let self else { return }
            let live = Set(
                (state.activeWindow.flatMap { state.window($0) }?.visibleLayout?.panes.map(\.pane)) ?? []
            )
            self.renderablePanes = live
            DebugLog.shared.log(.tmux, "onStateChanged: wins=\(state.windows.count) active=\(state.activeWindow.map(String.init(describing:)) ?? "nil") panes=\(live.count)")
            self.pendingPaneBytes = self.pendingPaneBytes.filter { live.contains($0.key) }
            let oldActive = self.tmuxState?.activeWindow.flatMap { self.tmuxState?.window($0)?.activePane }
            self.tmuxState = state
            DebugLog.shared.log(.tmux, "tmux:activeWindow=\(state.activeWindow.map { "@\($0.raw)" } ?? "nil") wins=\(state.windows.count)")
            self.snapshotStore?.rebuild(state: state)
            self.snapshotStore?.refreshNonActive(state: state)
            let newActive = state.activeWindow.flatMap { state.window($0)?.activePane }
            if oldActive != newActive {
                // Active pane changed (e.g. ⌘]) — re-publish the new active pane's
                // last-known title so the window title isn't left stale.
                self.terminalTitle = titleOnActiveChange(active: newActive, lastTitles: self.paneLastTitles)
            }
            self.refreshFnAutoEngage()
        }
        runtime.onContextsChanged = { [weak self, weak runtime] in
            guard let self, let runtime else { return }
            var map: [PaneID: String] = [:]
            for pane in self.renderablePanes {
                if let ctx = runtime.paneContext(pane) { map[pane] = ctx }
            }
            self.paneContexts = map
            self.refreshFnAutoEngage()
        }
        runtime.onExit = { [weak self] reason in
            DebugLog.shared.log(.lifecycle, "tmux onExit: reason=\(reason ?? "nil") → .failed")
            self?.state = .failed(reason ?? "tmux session ended")
        }
        // A pane already on the alternate screen before this -CC client attached
        // never emits `?1049h` for us to observe live, so `PaneModeTracker` would
        // otherwise misjudge it as `.localScroll`. Queue tmux's `#{alternate_on}`
        // truth here; `TmuxPaneContainer` (the modeTracker owner) applies it via
        // `takeAltScreenOverride` right after the pane's TerminalView is created;
        // this covers both orderings (query reply before or after pane mount).
        runtime.onAltScreenReconcile = { [weak self] pane, isAlt in
            guard let self else { return }
            if let view = self.paneViews[pane] {
                // Pane already mounted: apply immediately, do NOT queue (a queued copy
                // would be replayed against a later remount of a reused PaneID after
                // tmux window-switch churn, misapplying a stale fact).
                self.altScreenOverrideReady?(pane, isAlt, view)
            } else {
                // Reply arrived before the pane's TerminalView exists: queue for
                // `takeAltScreenOverride` to drain at mount.
                self.pendingAltScreenOverrides[pane] = isAlt
            }
        }
        // DIAGNOSTIC (temporary): surface what the runtime sees on attach so a blank
        // pane grid on device is self-explaining. Remove with the rest of the diag.
        runtime.onDiagnostic = { [weak self] summary in self?.tmuxDiag = summary }
        let sink = TerminalShellOutput()
        sink.onBytes = { [weak runtime] bytes in runtime?.ingest(bytes) }
        sink.onExit = { [weak self, weak runtime] exit in
            guard let self else { return }
            // A clean %exit is already handled by runtime.onExit (session ended).
            // An unexpected EOF while the connection is alive is a tmux crash:
            // drop to a raw shell on the same conn and raise the persistent banner.
            if let runtime, case .crashed = classifyTmuxClosure(lifecycle: runtime.lifecycle) {
                Task { await self.recoverFromTmuxCrash(conn: conn) }
            }
        }
        DebugLog.shared.log(.tmux, "attachTmux: openExec startCmd=\(startCmd.prefix(60))")
        let sess = try await conn.openExec(command: startCmd, term: "xterm-256color",
                                           cols: 80, rows: 24, output: sink)
        runtime.session = sess
        connection = conn
        session = sess
        self.tmux = runtime   // retain to keep control mode alive
        state = .shell
        DebugLog.shared.log(.lifecycle, "attachTmux: exec opened, tmux SET, state=.shell — awaiting tmux output")
        runtime.startContextPolling()
    }

    // MARK: - Crash recovery + banner actions

    /// Tmux crashed: reuse the live connection for a raw shell, then show the
    /// persistent crash banner. If the connection is also gone, surface a failure.
    private func recoverFromTmuxCrash(conn: Connection) async {
        DebugLog.shared.log(.lifecycle, "recoverFromTmuxCrash: tmux crashed → raw shell on live conn")
        tmux?.stop(); tmux = nil
        do {
            try await openRawShell(conn: conn)   // sets session/rawWriter, tmuxState=nil, state=.shell
            paneContexts = [:]
            fnState.reset()
            paneViews.removeAll()
            pendingPaneBytes.removeAll()
            renderablePanes.removeAll()
            DebugLog.shared.log(.lifecycle, "recoverFromTmuxCrash: raw shell up → crash banner")
            crashBanner = .tmuxEnded
        } catch {
            DebugLog.shared.log(.lifecycle, "recoverFromTmuxCrash: raw shell THREW \(String(describing: error)) → .failed")
            state = .failed("tmux ended and the connection is no longer reachable.")
        }
    }

    /// Banner action — reattach control mode on the live connection. `-CC
    /// new-session -A` attaches to the server-side session if it survived, else
    /// creates a fresh one.
    func reattachTmux() {
        DebugLog.shared.log(.lifecycle, "reattachTmux: conn=\(connection == nil ? "NIL" : "alive") tmux=\(tmux == nil ? "nil" : "SET") rawWriter=\(rawWriter == nil ? "nil" : "SET") tmuxState=\(tmuxState == nil ? "nil" : "set")")
        guard let conn = connection else { DebugLog.shared.log(.lifecycle, "reattachTmux: ABORT no connection"); return }
        crashBanner = nil
        Task {
            do { try await attachTmux(conn: conn) }
            catch { DebugLog.shared.log(.lifecycle, "reattachTmux: attach THREW → .failed"); state = .failed("Could not reattach: the connection is no longer reachable.") }
        }
    }

    /// Banner action — start a fresh tmux. Same `-CC new-session -A` path; if the
    /// old session somehow survived this reattaches to it (acceptable for v1 —
    /// distinct fresh-session naming is a follow-up).
    func startNewTmux() {
        guard let conn = connection else {
            DebugLog.shared.log(.lifecycle, "startNewTmux: ABORT no connection")
            return
        }
        crashBanner = nil
        Task {
            do { try await attachTmux(conn: conn) }
            catch {
                DebugLog.shared.log(.lifecycle, "startNewTmux: attach THREW → .failed")
                state = .failed("Could not start tmux: the connection is no longer reachable.")
            }
        }
    }

    /// Banner action — stay in degraded raw-shell mode for the rest of the session.
    func dismissCrashBanner() { crashBanner = nil }

    // MARK: - Predictor

    /// Persist the session's learned predictor vocabulary to disk. Idempotent and
    /// safe to call repeatedly; a no-op when the predictor is disabled (incognito)
    /// or no learned store is attached. Called from `teardown()` and on
    /// app-background (`scenePhase`) so learning survives a backgrounded or killed
    /// app — previously only a clean teardown flushed. The snapshot+save now runs on
    /// a detached `Task` (the engine lives behind `PredictorActor`); the actor
    /// reference is captured before any subsequent `predictor = nil`, so the flush
    /// completes against the correct engine even as teardown proceeds.
    func flushPredictor() {
        guard let predictor, let learnedStore else { return }
        Task { let s = await predictor.snapshotState(); try? learnedStore.save(s) }
    }

    /// Forget the most-recently-typed line's un-graduated tokens (surgical L7 tool).
    /// Surfaced by the predictor strip's eraser. No-op when the predictor is off.
    func forgetLastLine() {
        DebugLog.shared.log(.predictor, "predictor:forgetLastLine")
        Task { [predictor] in await predictor?.forgetLastLine() }
        // Ephemeral drop — nothing to persist; suggestions refresh on next input.
    }

    /// `PredictorPurgeable`: reset the running engine to empty (seed preserved).
    /// Called by `AppStores.purgePredictorLearned()` when THIS session is the active
    /// one, so a panic-purge triggered from Settings — even mid-session — clears the
    /// in-memory learned state before the on-disk store is deleted. No-op when the
    /// predictor is off (incognito).
    func purgeLearnedEngine() {
        DebugLog.shared.log(.predictor, "predictor:purge")
        Task { [predictor] in await predictor?.purgeLearned() }
    }

    /// Panic-purge: wipe all user-derived predictor state now (live engine + disk).
    /// Delegates to the store, which resets this session's engine (via the
    /// `activePredictorSession` registration) before deleting the file, so there is
    /// no stale-write-back window.
    ///
    /// Reserved as an in-session call site (e.g. a session-UI purge button); today
    /// `PrivacySettingsView` drives the purge through `AppStores` directly and the
    /// registration handles the live engine, so this convenience wrapper has no
    /// caller yet.
    func panicPurge() {
        try? AppStores.shared.purgePredictorLearned()
    }

    /// Build the session predictor unless incognito is on for this host.
    private func startPredictor(host: Host, defaults: Defaults) {
        guard !resolvePredictorIncognito(host: host, defaults: defaults) else {
            predictor = nil
            // Incognito: no engine to reset, so don't claim the active-purge slot.
            if AppStores.shared.activePredictorSession === self {
                AppStores.shared.activePredictorSession = nil
            }
            return
        }
        let store = AppStores.shared.predictorLearnedStore()
        learnedStore = store
        predictor = PredictorActor(engine: PredictorEngine(learned: store.load(), seed: AppStores.shared.predictorSeed()))
        // Register as the session a Settings-triggered panic-purge should reset.
        AppStores.shared.activePredictorSession = self
    }

    /// Fold outgoing bytes into the token tracker, learn committed tokens (unless
    /// the line is a password entry), and refresh the suggestion chips.
    ///
    /// Learning is gated by `passwordDetector`: tokens committed on a line are
    /// buffered and only recorded once the line commits (Enter) AND the detector
    /// confirms the line was echoed and not preceded by a password prompt. A
    /// space-committed token mid-line is held until its line's verdict is known,
    /// so a multi-word line is learned or dropped as a unit. This keeps typed
    /// passwords (sudo / ssh / passphrase prompts) out of the synced vocabulary;
    /// the token filter alone can't catch a short low-entropy password.
    private func observePredictorInput(_ bytes: [UInt8]) {
        guard predictor != nil else { return }
        // L1: snapshot the pre-delivery cursor as THIS call's echo anchor, then
        // after a bounded window classify this call's keystrokes against the grid.
        // The anchor is captured per-call (not shared state), so concurrent
        // per-keystroke settles never clobber each other.
        let scalars = predictorScalars(bytes)
        let anchor = scalars.isEmpty ? nil : passwordDetector.currentCursor()
        passwordDetector.noteInput(bytes)
        for committed in tracker.observe(bytes) {
            pendingLineTokens.append(committed)
        }
        // If this chunk left the line empty with no usable preceding token (an ESC /
        // Ctrl-* / control line reset, or a backspace-to-empty), clear stale chips now.
        // Enter is already handled synchronously below; the normal typing case has a
        // non-empty `current` so this is a no-op there. (predictor-suggestion-hygiene
        // spec, Fix 4: "clear on ESC/control line reset".)
        if tracker.current.isEmpty, tracker.previous?.isEmpty != false {
            predictorVM.setSuggestions([])
        }
        // L4a: the tracker latches the just-committed line's opt-out at its Enter,
        // so this is correct even when a leading-space line and its Enter arrive in
        // ONE chunk (paste). (Per-chunk coarseness matches L1's: a chunk with two
        // full lines of mixed opt-out applies the last line's verdict — a known v1
        // limit, not a realistic paste-a-secret case.)
        let optedOut = tracker.lastCommittedLineOptedOut
        let deadline = DispatchTime.now() + .milliseconds(40)
        // `observePredictorInput` and the coalescer are both @MainActor (this VM is
        // @MainActor; the only caller is `sendTerminalInput`), so no lock is needed.
        // Settle and refresh run in the same hop in program order: no fragile
        // wall-clock offsets between them (findings C/D).
        if !scalars.isEmpty {
            refreshCoalescer.requestRefresh(at: Date().timeIntervalSinceReferenceDate)
            DispatchQueue.main.asyncAfter(deadline: deadline) { [weak self] in
                guard let self else { return }
                // 1) settle echo against the grid (L1), THEN
                self.passwordDetector.settleLine(scalars: scalars, from: anchor)
                // 2) recompute suggestions in the same main-actor hop, in program order,
                //    so the refresh always reflects post-settle state (findings C/D — no
                //    fragile inter-hop wall-clock offsets). Trailing-debounce preserved:
                //    only recompute if no newer keystroke arrived.
                if self.refreshCoalescer.isDue(at: Date().timeIntervalSinceReferenceDate) {
                    self.refreshPredictorSuggestions()
                }
            }
        }
        for b in bytes where b == 0x0d || b == 0x0a {
            predictorVM.setSuggestions([])   // line committed → clear stale chips immediately
            // This closure runs on the main queue and touches @MainActor state (passwordDetector,
            // pendingLineTokens) and the @MainActor DebugLog directly — legal via the closure's
            // inferred main-actor isolation. If ever extracted to a @Sendable/non-capturing form,
            // the DebugLog + self accesses need an explicit MainActor.assumeIsolated/await.
            DispatchQueue.main.asyncAfter(deadline: deadline + .milliseconds(10)) { [weak self] in
                guard let self else { return }
                let echoConfirmed = self.passwordDetector.shouldLearnCommittedLine()
                // Learn only if L1 confirms echo AND the line was not opted out (L4a); the
                // engine still folds echo/opt-out/L5 into the L7 confidence tier.
                if !optedOut, echoConfirmed {
                    let toLearn = self.pendingLineTokens
                    DebugLog.shared.log(.predictor,
                        "predictor:record tokens=\(toLearn.count) echo=\(echoConfirmed) optedOut=\(optedOut)")
                    Task { [predictor = self.predictor] in
                        await predictor?.beginLine()
                        await predictor?.record(toLearn, echoConfirmed: echoConfirmed, optedOut: optedOut)
                    }
                } else {
                    DebugLog.shared.log(.predictor,
                        "predictor:recordSuppressed echo=\(echoConfirmed) optedOut=\(optedOut)")
                }
                self.pendingLineTokens.removeAll(keepingCapacity: true)
                self.passwordDetector.resetLine()
            }
        }
    }

    private func refreshPredictorSuggestions() {
        guard let predictor else { predictorVM.setSuggestions([]); return }
        let prefix = tracker.current, prev = tracker.previous
        // Mirror the engine's conditional min-prefix floor so a short from-scratch prefix
        // clears chips instead of leaving stale ones up. The bigram path (a usable
        // `prev`) is exempt — next-token suggestions are valid with an empty prefix.
        // NOTE: literal `2` must stay in sync with SuggestionConfig.minPrefix (currently 2).
        // A future task can plumb the config value through; out of scope here.
        let hasUsablePrevious = (prev?.isEmpty == false)
        if !hasUsablePrevious, prefix.count < 2 { predictorVM.setSuggestions([]); return }
        Task { [weak self] in
            let raw = await predictor.suggestions(forPrefix: prefix, after: prev)
            let chips = predictorChips(current: prefix, suggestions: raw)
            await MainActor.run {
                DebugLog.shared.log(.predictor, "predictor:suggest prefixLen=\(prefix.count) results=\(raw.count)")
                self?.predictorVM.setSuggestions(chips)
            }
        }
    }

    /// Accept a chip: send only the missing suffix so the existing input is kept
    /// (never rewritten). The suffix flows back through `sendTerminalInput`, so the
    /// tracker and suggestions update automatically.
    func acceptSuggestion(_ s: String) {
        guard s.hasPrefix(tracker.current) else { return }
        let suffix = String(s.dropFirst(tracker.current.count))
        guard !suffix.isEmpty else { return }
        predictorVM.setSuggestions([])   // clear immediately; the echo round-trip repopulates from the new prefix
        sendTerminalInput(Array(suffix.utf8))
    }

    // MARK: - Connect (saved host)

    /// Connect from a saved `Host` record, using its resolved config and a
    /// caller-supplied password. Does NOT create or modify any host record
    /// (contrast with `connect(host:port:user:password:)` which calls
    /// `findOrCreateHost`). Throws a user-facing `.failed` state if the user
    /// field cannot be resolved.
    func connect(savedHost: Host, password: String) {
        if state == .connecting || state == .shell {
            DebugLog.shared.log(.connect, "connect(saved): IGNORED — already \(state == .connecting ? "connecting" : "in shell")")
            return
        }
        lastSavedHost = savedHost
        lastPassword = password
        teardown()
        state = .connecting
        degraded = nil
        let defaults = (try? AppStores.shared.hosts.defaults()) ?? Defaults()
        let user: String
        do {
            user = try resolveUser(host: savedHost, defaults: defaults)
        } catch ResolutionError.userUnset {
            DebugLog.shared.log(.connect, "connect(saved): user unset → .failed (pre-connect)")
            state = .failed("Set a user for this host or in Defaults to connect.")
            return
        } catch {
            DebugLog.shared.log(.connect, "connect(saved): resolveUser THREW \(String(describing: error)) → .failed")
            state = .failed(String(describing: error))
            return
        }
        let port = resolvePort(host: savedHost, defaults: defaults)
        let addr = "\(savedHost.hostName):\(port)"
        output.onExit = { [weak self] exit in
            DebugLog.shared.log(.connect, "connect(saved): output.onExit → .failed(\(exit.error ?? "Session closed"))")
            self?.state = .failed(exit.error ?? "Session closed")
        }
        DebugLog.shared.log(.connect, "connect(saved): START addr=\(addr) user=\(user)")
        Task {
            do {
                let verifier = TofuHostKeyVerifier(
                    hostID: savedHost.id, trust: AppStores.shared.trust,
                    present: { [weak self] prompt in await self?.present(prompt) ?? false })
                let conn = try await SemicolynSSHCoreFFI.connect(
                    addr: addr, allowLegacy: false, allowDeprecated: false,
                    keepalive: keepaliveConfig(host: savedHost, defaults: defaults),
                    verifier: verifier)
                DebugLog.shared.log(.connect, "connect(saved): TCP+handshake OK, authenticating")
                let outcome = try await authenticate(conn: conn, user: user, host: savedHost, defaults: defaults, password: password)
                switch outcome {
                case .success:
                    DebugLog.shared.log(.connect, "connect(saved): auth SUCCESS")
                default:
                    DebugLog.shared.log(.connect, "connect(saved): auth FAILED (\(String(describing: outcome))) → .failed")
                    state = .failed("Authentication failed")
                    return
                }
                // Probe + branch on tmux availability.
                let defaults2 = (try? AppStores.shared.hosts.defaults()) ?? Defaults()
                osc52Allowed = resolveOsc52Allow(host: savedHost, defaults: defaults2)
                startPredictor(host: savedHost, defaults: defaults2)
                // Mosh takes precedence over tmux when enabled + bootstrappable.
                if await attachMoshIfPossible(conn: conn, host: savedHost, defaults: defaults2) {
                    DebugLog.shared.log(.connect, "connect(saved): went MOSH path")
                    return
                }
                DebugLog.shared.log(.lifecycle, "connect(saved): → attachSSHShell (tmux/raw)")
                try await attachSSHShell(conn: conn, host: savedHost, defaults: defaults2)
            } catch ConnectError.HostKeyRejected {
                DebugLog.shared.log(.connect, "connect(saved): HostKeyRejected → .failed")
                state = .failed("Host key not trusted")
            } catch ConnectError.Timeout {
                DebugLog.shared.log(.connect, "connect(saved): Timeout → .failed")
                state = .failed("Couldn't reach host — connection timed out")
            } catch {
                DebugLog.shared.log(.connect, "connect(saved): THREW \(String(describing: error)) → .failed")
                state = .failed(String(describing: error))
            }
        }
    }

    // MARK: - Connect (ad-hoc)

    func connect(host: String, port: String, user: String, password: String) {
        if state == .connecting || state == .shell {
            DebugLog.shared.log(.connect, "connect(adhoc): IGNORED — already \(state == .connecting ? "connecting" : "in shell")")
            return
        }
        teardown()
        state = .connecting
        degraded = nil
        let addr = "\(host):\(port.isEmpty ? "22" : port)"
        output.onExit = { [weak self] exit in
            DebugLog.shared.log(.connect, "connect(adhoc): output.onExit → .failed(\(exit.error ?? "Session closed"))")
            self?.state = .failed(exit.error ?? "Session closed")
        }
        DebugLog.shared.log(.connect, "connect(adhoc): START addr=\(addr) user=\(user)")
        Task {
            do {
                let portNum = Int(port) ?? 22
                let hostRecord = try findOrCreateHost(hostName: host, port: portNum, user: user)
                let defaults = (try? AppStores.shared.hosts.defaults()) ?? Defaults()
                let verifier = TofuHostKeyVerifier(
                    hostID: hostRecord.id, trust: AppStores.shared.trust,
                    present: { [weak self] prompt in await self?.present(prompt) ?? false })
                let conn = try await SemicolynSSHCoreFFI.connect(
                    addr: addr, allowLegacy: false, allowDeprecated: false,
                    keepalive: keepaliveConfig(host: hostRecord, defaults: defaults),
                    verifier: verifier)
                DebugLog.shared.log(.connect, "connect(adhoc): TCP+handshake OK, authenticating")
                let outcome = try await authenticate(conn: conn, user: user, host: hostRecord, defaults: defaults, password: password)
                switch outcome {
                case .success:
                    DebugLog.shared.log(.connect, "connect(adhoc): auth SUCCESS")
                default:
                    DebugLog.shared.log(.connect, "connect(adhoc): auth FAILED (\(String(describing: outcome))) → .failed")
                    state = .failed("Authentication failed")
                    return
                }
                // Probe + branch on tmux availability.
                let defaults2 = (try? AppStores.shared.hosts.defaults()) ?? Defaults()
                osc52Allowed = resolveOsc52Allow(host: hostRecord, defaults: defaults2)
                startPredictor(host: hostRecord, defaults: defaults2)
                // Mosh takes precedence over tmux when enabled + bootstrappable.
                if await attachMoshIfPossible(conn: conn, host: hostRecord, defaults: defaults2) {
                    DebugLog.shared.log(.connect, "connect(adhoc): went MOSH path")
                    return
                }
                DebugLog.shared.log(.lifecycle, "connect(adhoc): → attachSSHShell (tmux/raw)")
                try await attachSSHShell(conn: conn, host: hostRecord, defaults: defaults2)
            } catch ConnectError.HostKeyRejected {
                DebugLog.shared.log(.connect, "connect(adhoc): HostKeyRejected → .failed")
                state = .failed("Host key not trusted")
            } catch ConnectError.Timeout {
                DebugLog.shared.log(.connect, "connect(adhoc): Timeout → .failed")
                state = .failed("Couldn't reach host — connection timed out")
            } catch {
                DebugLog.shared.log(.connect, "connect(adhoc): THREW \(String(describing: error)) → .failed")
                state = .failed(String(describing: error))
            }
        }
    }

    /// Resolves the host's keepalive policy (OpenSSH `ServerAliveInterval` /
    /// `ServerAliveCountMax`) into the Rust core's `KeepaliveConfig`, so an idle
    /// interactive session stays alive. `interval == 0` disables keepalives
    /// (the resolve fallbacks are 30 / 3).
    private func keepaliveConfig(host: Host, defaults: Defaults) -> KeepaliveConfig {
        KeepaliveConfig(
            intervalSecs: UInt32(max(0, resolveServerAliveInterval(host: host, defaults: defaults))),
            countMax: UInt32(max(0, resolveServerAliveCountMax(host: host, defaults: defaults))))
    }
}
