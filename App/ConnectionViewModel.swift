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
    /// Top-K predictor chips for the current input token (empty → strip hidden).
    @Published private(set) var predictorSuggestions: [String] = []
    /// Nil when the predictor is disabled for this session (incognito).
    private var engine: PredictorEngine?
    private var tracker = InputTokenTracker()
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

    private var promptContinuation: CheckedContinuation<Bool, Never>?

    private var connection: Connection?
    /// Non-nil while a Mosh session is driving the terminal (mutually exclusive
    /// with `tmux`). Retained so teardown can shut the UDP loop down.
    private var moshSession: MoshSession?
    /// True once the current Mosh session has delivered its first output frame (the
    /// UDP handshake completed). Gates `onEnd`: a pre-first-frame exit falls back to
    /// SSH on the retained connection; a post-first-frame exit is a mid-session crash.
    private var moshFirstFrameSeen = false
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
        await withCheckedContinuation { cont in
            promptContinuation?.resume(returning: false)
            promptContinuation = cont
            pendingPrompt = prompt
        }
    }

    /// Called by the view when the user taps a modal button.
    func resolvePrompt(_ trusted: Bool) {
        pendingPrompt = nil
        promptContinuation?.resume(returning: trusted)
        promptContinuation = nil
    }

    // MARK: - Input routing

    func fnTap()       { fnState.tap() }
    func fnDoubleTap() { fnState.doubleTap() }
    /// Send an F-key and clear a one-shot Fn arm.
    func fnTapFKey(_ n: Int) { keybar.tapFKey(n); fnState.fireFKey() }

    /// Route terminal keystrokes: through tmux `send-keys` when control mode is
    /// attached, else straight to the raw-PTY channel.
    func sendTerminalInput(_ bytes: [UInt8]) {
        // The keystroke is sacred: write to the transport BEFORE any predictor work,
        // so send latency is independent of predictor cost (Plan B).
        if let moshSession {
            moshSession.writeInput(Data(bytes))
        } else if let tmux {
            tmux.sendInput(bytes)
        } else {
            rawWriter?.enqueue(bytes)
        }
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

    /// Called by TmuxPaneContainer when a pane's view is created. Flushes any
    /// bytes that arrived before the view existed.
    func registerPane(_ pane: PaneID, _ view: TerminalView) {
        paneViews[pane] = view
        if let buffered = pendingPaneBytes[pane] {
            view.feed(byteArray: buffered[...]); pendingPaneBytes[pane] = nil
        }
    }

    func unregisterPane(_ pane: PaneID) { paneViews[pane] = nil; pendingPaneBytes[pane] = nil; paneLastTitles[pane] = nil }

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

    func selectWindow(_ id: WindowID) { tmux?.selectWindow(id) }

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

    // MARK: - Hardware-keyboard commands (Phase 4e)

    /// Dispatches a resolved hardware-keyboard command to its action. Window/pane
    /// commands no-op in raw-PTY mode (no `tmux`); presentation commands publish a
    /// `presentedSheet` intent for `SessionView`.
    func perform(_ command: KeyboardCommand) {
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
        guard let host = lastSavedHost else { return }
        connect(savedHost: host, password: lastPassword ?? "")
    }

    /// Push the tmux client size so it re-tiles. The grid is computed accurately by
    /// `TmuxPaneContainer` (container bounds ÷ measured cell), debounced there.
    func setTmuxClientSize(cols: Int, rows: Int) { tmux?.setClientSize(cols: cols, rows: rows) }

    // MARK: - Teardown

    /// User-initiated disconnect (the connected-state Disconnect button). Tears the
    /// session down and flips `state` to `.idle` so the view can dismiss back to the
    /// host list. Flushes the predictor first (teardown already does), so learning
    /// survives an explicit disconnect just like a backgrounded one.
    func disconnect() {
        teardown()
        state = .idle
    }

    /// Reset all connection and pane state. Call at the start of each connect
    /// attempt so no stale handles or buffered bytes carry over to the new session.
    private func teardown() {
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
        // can't feed a torn-down terminal view or a cleared engine. Both are
        // re-installed when the next shell opens.
        output.onBytes = nil
        output.onHarvestBytes = nil
        engine = nil
        // Deregister from the active-purge slot (the VM may be reused on reconnect
        // without deallocating, so the weak ref alone isn't enough).
        if AppStores.shared.activePredictorSession === self {
            AppStores.shared.activePredictorSession = nil
        }
        tracker.reset()
        passwordDetector.reset()          // clear echo/prompt state across sessions
        pendingLineTokens.removeAll()     // drop any un-flushed line tokens
        predictorSuggestions = []
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
                return try await conn.authenticatePublickey(user: user, privateKeyOpenssh: key)
            }
        }
        return try await conn.authenticatePassword(user: user, password: password)
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
        guard probeSession != nil else { return nil }
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
        return text.isEmpty ? nil : text
    }

    /// Open a raw PTY shell: the original pre-tmux path. Sets `connection`,
    /// `session`, and `state = .shell`.
    private func openRawShell(conn: Connection) async throws {
        let sess = try await conn.openShell(
            term: "xterm-256color", cols: 80, rows: 24, output: output)
        connection = conn
        session = sess
        rawWriter = SerialByteWriter(sink: ShellSessionSink(session: sess))
        tmuxState = nil   // raw mode: single-terminal path
        // Harvest raw-shell output for the predictor through the dedicated harvest
        // slot. `TerminalScreen.makeUIView` installs its render closure into
        // `output.onBytes`; using `onHarvestBytes` lets both fire from `onOutput`
        // (previously the render closure clobbered this and degraded-mode output
        // never trained the predictor).
        output.onHarvestBytes = { [weak self] bytes in
            guard let self else { return }
            // Feed the output stream to the password gate (echo inference +
            // prompt-text) so it can classify the next typed line.
            self.passwordDetector.noteOutput(bytes)
            self.engine?.harvest(output: String(decoding: bytes, as: UTF8.self))
        }
        state = .shell
    }

    /// Probe tmux on the authenticated connection and attach the tmux control-mode
    /// session or fall back to a degraded raw shell. This is the shared SSH tail of
    /// both `connect` methods, factored out so the Mosh pre-frame fallback can re-run
    /// it on the SAME retained connection (see `attachMoshIfPossible`).
    private func attachSSHShell(conn: Connection, host: Host, defaults: Defaults) async throws {
        let allow = resolveTmuxAttemptControlMode(host: host, defaults: defaults)
        let probe = allow ? await probeTmuxVersion(conn: conn) : nil
        switch tmuxLaunchDecision(attemptControlMode: allow, versionProbe: probe) {
        case .attach:
            self.tmuxSessionNameForConnection = resolveTmuxSessionName(host: host, defaults: defaults)
            try await attachTmux(conn: conn)
        case .degrade(let reason):
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
        guard sess != nil else { return "" }
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
        guard resolveMoshEnabled(host: host, defaults: defaults) else { return false }
        // Effective config for the argv (port range, server path, prediction mode).
        // resolveOptional honors Inherited three-state (NOT host.mosh.value).
        let cfg = resolveOptional(host.mosh, defaults.mosh) ?? MoshConfig(enabled: true)
        let command = moshServerCommand(cfg).joined(separator: " ")
        let stdout = await captureMoshBootstrap(conn: conn, command: command)
        switch moshBranchOutcome(stdout: stdout, enabled: true) {
        case let .mosh(port, key):
            let predict = cfg.predictionMode?.rawValue ?? "adaptive"
            // Seeded at 80×24: the terminal view hasn't laid out yet at connect time,
            // so the real grid isn't known here. The first debounced resize from
            // TerminalScreen (via setMoshClientSize) corrects it once layout happens,
            // and mosh reflows. FUTURE (item #5 Q2(b)): to skip the brief 80×24 first
            // frame, track the last-known terminal grid on the VM and pass it here.
            let sess = MoshSession(ip: host.hostName, port: String(port), key: key,
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
                // Frames are flowing: the UDP path is up. From here on, loop exits are
                // mid-session events, not handshake failures.
                self?.moshFirstFrameSeen = true
            }
            sess.onEnd = { [weak self] _ in
                guard let self else { return }
                if self.moshFirstFrameSeen {
                    // Post-first-frame exit (session/server death, clean or not).
                    // Tear the dead Mosh session down FIRST: sendTerminalInput checks
                    // `moshSession` before tmux/raw, so a lingering non-nil session
                    // would swallow every keystroke into the dead input pipe (EPIPE,
                    // silently dropped) after the user reattaches tmux via the banner.
                    // stop() is idempotent and joins the already-exiting mosh thread.
                    self.moshSession?.stop()
                    self.moshSession = nil
                    self.moshFirstFrameSeen = false
                    // Then reuse the mid-session crash banner — the same state tmux uses.
                    self.crashBanner = .tmuxEnded
                    return
                }
                // Pre-first-frame exit: the UDP handshake never completed (blocked
                // firewall / crypto mismatch). Fall back to SSH on the SAME retained
                // connection with a banner, instead of dead-ending the whole connect.
                self.moshSession?.stop()
                self.moshSession = nil
                self.moshFallback = "Mosh UDP unreachable (check firewall) — using SSH"
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        try await self.attachSSHShell(conn: conn, host: host, defaults: defaults)
                    } catch {
                        self.state = .failed(String(describing: error))
                    }
                }
            }
            sess.start()
            moshSession = sess
            connection = conn
            tmuxState = nil
            state = .shell
            return true
        case let .fallback(reason):
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
        let runtime = TmuxRuntime(sessionName: tmuxSessionNameForConnection)
        guard let startCmd = runtime.makeStartCommand() else {
            // Controller couldn't build a start command (e.g. an invalid resolved
            // session name — which a Defaults-level value can be, since the Defaults
            // editor has no per-field validation). Surface it via the degraded
            // banner instead of silently dropping to a raw shell everywhere.
            degraded = .couldNotStart
            try await openRawShell(conn: conn)
            return
        }
        runtime.onPaneBytes = { [weak self] pane, bytes in
            guard let self else { return }
            if let view = self.paneViews[pane] {
                view.feed(byteArray: bytes[...])
            } else if self.renderablePanes.contains(pane) {
                self.pendingPaneBytes[pane, default: []].append(contentsOf: bytes)
            } else {
                // Pane not in the visible layout — drop to prevent unbounded
                // buffering, and don't harvest output the user can't see.
                return
            }
            // Harvest pane output for the predictor — visible panes only (a live
            // view or pending registration), not filtered by active pane.
            self.passwordDetector.noteOutput(bytes)
            self.engine?.harvest(output: String(decoding: bytes, as: UTF8.self))
        }
        runtime.onStateChanged = { [weak self] state in
            guard let self else { return }
            let live = Set(
                (state.activeWindow.flatMap { state.window($0) }?.visibleLayout?.panes.map(\.pane)) ?? []
            )
            self.renderablePanes = live
            self.pendingPaneBytes = self.pendingPaneBytes.filter { live.contains($0.key) }
            let oldActive = self.tmuxState?.activeWindow.flatMap { self.tmuxState?.window($0)?.activePane }
            self.tmuxState = state
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
        runtime.onExit = { [weak self] reason in self?.state = .failed(reason ?? "tmux session ended") }
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
        let sess = try await conn.openExec(command: startCmd, term: "xterm-256color",
                                           cols: 80, rows: 24, output: sink)
        runtime.session = sess
        connection = conn
        session = sess
        self.tmux = runtime   // retain to keep control mode alive
        state = .shell
        runtime.startContextPolling()
    }

    // MARK: - Crash recovery + banner actions

    /// Tmux crashed: reuse the live connection for a raw shell, then show the
    /// persistent crash banner. If the connection is also gone, surface a failure.
    private func recoverFromTmuxCrash(conn: Connection) async {
        tmux?.stop(); tmux = nil
        do {
            try await openRawShell(conn: conn)   // sets session/rawWriter, tmuxState=nil, state=.shell
            paneContexts = [:]
            fnState.reset()
            paneViews.removeAll()
            pendingPaneBytes.removeAll()
            renderablePanes.removeAll()
            crashBanner = .tmuxEnded
        } catch {
            state = .failed("tmux ended and the connection is no longer reachable.")
        }
    }

    /// Banner action — reattach control mode on the live connection. `-CC
    /// new-session -A` attaches to the server-side session if it survived, else
    /// creates a fresh one.
    func reattachTmux() {
        guard let conn = connection else { return }
        crashBanner = nil
        Task {
            do { try await attachTmux(conn: conn) }
            catch { state = .failed("Could not reattach: the connection is no longer reachable.") }
        }
    }

    /// Banner action — start a fresh tmux. Same `-CC new-session -A` path; if the
    /// old session somehow survived this reattaches to it (acceptable for v1 —
    /// distinct fresh-session naming is a follow-up).
    func startNewTmux() {
        guard let conn = connection else { return }
        crashBanner = nil
        Task {
            do { try await attachTmux(conn: conn) }
            catch { state = .failed("Could not start tmux: the connection is no longer reachable.") }
        }
    }

    /// Banner action — stay in degraded raw-shell mode for the rest of the session.
    func dismissCrashBanner() { crashBanner = nil }

    // MARK: - Predictor

    /// Persist the session's learned predictor vocabulary to disk. Idempotent and
    /// safe to call repeatedly; a no-op when the predictor is disabled (incognito)
    /// or no learned store is attached. Called from `teardown()` and on
    /// app-background (`scenePhase`) so learning survives a backgrounded or killed
    /// app — previously only a clean teardown flushed.
    func flushPredictor() {
        guard let engine, let learnedStore else { return }
        try? learnedStore.save(engine.state)
    }

    /// Forget the most-recently-typed line's un-graduated tokens (surgical L7 tool).
    /// Surfaced by the predictor strip's eraser. No-op when the predictor is off.
    func forgetLastLine() {
        engine?.forgetLastLine()
        // Ephemeral drop — nothing to persist; suggestions refresh on next input.
    }

    /// `PredictorPurgeable`: reset the running engine to empty (seed preserved).
    /// Called by `AppStores.purgePredictorLearned()` when THIS session is the active
    /// one, so a panic-purge triggered from Settings — even mid-session — clears the
    /// in-memory learned state before the on-disk store is deleted. No-op when the
    /// predictor is off (incognito).
    func purgeLearnedEngine() {
        engine?.purgeLearned()
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
            engine = nil
            // Incognito: no engine to reset, so don't claim the active-purge slot.
            if AppStores.shared.activePredictorSession === self {
                AppStores.shared.activePredictorSession = nil
            }
            return
        }
        let store = AppStores.shared.predictorLearnedStore()
        learnedStore = store
        engine = PredictorEngine(learned: store.load(), seed: AppStores.shared.predictorSeed())
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
        guard engine != nil else { return }
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
        // L4a: the tracker latches the just-committed line's opt-out at its Enter,
        // so this is correct even when a leading-space line and its Enter arrive in
        // ONE chunk (paste). (Per-chunk coarseness matches L1's: a chunk with two
        // full lines of mixed opt-out applies the last line's verdict — a known v1
        // limit, not a realistic paste-a-secret case.)
        let optedOut = tracker.lastCommittedLineOptedOut
        let deadline = DispatchTime.now() + .milliseconds(40)
        if !scalars.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: deadline) { [weak self] in
                self?.passwordDetector.settleLine(scalars: scalars, from: anchor)
                self?.refreshPredictorSuggestions()
            }
        }
        for b in bytes where b == 0x0d || b == 0x0a {
            DispatchQueue.main.asyncAfter(deadline: deadline + .milliseconds(10)) { [weak self] in
                guard let self else { return }
                let echoConfirmed = self.passwordDetector.shouldLearnCommittedLine()
                // Learn only if L1 confirms echo AND the line was not opted out (L4a); the
                // engine still folds echo/opt-out/L5 into the L7 confidence tier.
                if !optedOut, echoConfirmed {
                    self.engine?.beginLine()
                    for c in self.pendingLineTokens {
                        self.engine?.record(c.token, after: c.previous,
                                            echoConfirmed: echoConfirmed, optedOut: optedOut)
                    }
                }
                self.pendingLineTokens.removeAll(keepingCapacity: true)
                self.passwordDetector.resetLine()
            }
        }
        refreshPredictorSuggestions()
    }

    private func refreshPredictorSuggestions() {
        guard let engine else { predictorSuggestions = []; return }
        let raw = engine.suggestions(forPrefix: tracker.current, after: tracker.previous)
        predictorSuggestions = predictorChips(current: tracker.current, suggestions: raw)
    }

    /// Accept a chip: send only the missing suffix so the existing input is kept
    /// (never rewritten). The suffix flows back through `sendTerminalInput`, so the
    /// tracker and suggestions update automatically.
    func acceptSuggestion(_ s: String) {
        guard s.hasPrefix(tracker.current) else { return }
        let suffix = String(s.dropFirst(tracker.current.count))
        guard !suffix.isEmpty else { return }
        sendTerminalInput(Array(suffix.utf8))
    }

    // MARK: - Connect (saved host)

    /// Connect from a saved `Host` record, using its resolved config and a
    /// caller-supplied password. Does NOT create or modify any host record
    /// (contrast with `connect(host:port:user:password:)` which calls
    /// `findOrCreateHost`). Throws a user-facing `.failed` state if the user
    /// field cannot be resolved.
    func connect(savedHost: Host, password: String) {
        if state == .connecting || state == .shell { return }
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
            state = .failed("Set a user for this host or in Defaults to connect.")
            return
        } catch {
            state = .failed(String(describing: error))
            return
        }
        let port = resolvePort(host: savedHost, defaults: defaults)
        let addr = "\(savedHost.hostName):\(port)"
        output.onExit = { [weak self] exit in
            self?.state = .failed(exit.error ?? "Session closed")
        }
        Task {
            do {
                let verifier = TofuHostKeyVerifier(
                    hostID: savedHost.id, trust: AppStores.shared.trust,
                    present: { [weak self] prompt in await self?.present(prompt) ?? false })
                let conn = try await SemicolynSSHCoreFFI.connect(
                    addr: addr, allowLegacy: false, allowDeprecated: false,
                    keepalive: keepaliveConfig(host: savedHost, defaults: defaults),
                    verifier: verifier)
                let outcome = try await authenticate(conn: conn, user: user, host: savedHost, defaults: defaults, password: password)
                switch outcome {
                case .success:
                    break
                default:
                    state = .failed("Authentication failed")
                    return
                }
                // Probe + branch on tmux availability.
                let defaults2 = (try? AppStores.shared.hosts.defaults()) ?? Defaults()
                osc52Allowed = resolveOsc52Allow(host: savedHost, defaults: defaults2)
                startPredictor(host: savedHost, defaults: defaults2)
                // Mosh takes precedence over tmux when enabled + bootstrappable.
                if await attachMoshIfPossible(conn: conn, host: savedHost, defaults: defaults2) {
                    return
                }
                try await attachSSHShell(conn: conn, host: savedHost, defaults: defaults2)
            } catch ConnectError.HostKeyRejected {
                state = .failed("Host key not trusted")
            } catch ConnectError.Timeout {
                state = .failed("Couldn't reach host — connection timed out")
            } catch {
                state = .failed(String(describing: error))
            }
        }
    }

    // MARK: - Connect (ad-hoc)

    func connect(host: String, port: String, user: String, password: String) {
        if state == .connecting || state == .shell { return }   // ignore re-taps
        teardown()
        state = .connecting
        degraded = nil
        let addr = "\(host):\(port.isEmpty ? "22" : port)"
        output.onExit = { [weak self] exit in
            self?.state = .failed(exit.error ?? "Session closed")
        }
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
                let outcome = try await authenticate(conn: conn, user: user, host: hostRecord, defaults: defaults, password: password)
                switch outcome {
                case .success:
                    break
                default:
                    state = .failed("Authentication failed")
                    return
                }
                // Probe + branch on tmux availability.
                let defaults2 = (try? AppStores.shared.hosts.defaults()) ?? Defaults()
                osc52Allowed = resolveOsc52Allow(host: hostRecord, defaults: defaults2)
                startPredictor(host: hostRecord, defaults: defaults2)
                // Mosh takes precedence over tmux when enabled + bootstrappable.
                if await attachMoshIfPossible(conn: conn, host: hostRecord, defaults: defaults2) {
                    return
                }
                try await attachSSHShell(conn: conn, host: hostRecord, defaults: defaults2)
            } catch ConnectError.HostKeyRejected {
                state = .failed("Host key not trusted")
            } catch ConnectError.Timeout {
                state = .failed("Couldn't reach host — connection timed out")
            } catch {
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
