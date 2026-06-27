// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import SwiftTerm
import UIKit
import NeotildeKit
import NeotildeSSHCoreFFI

/// Crash-banner presentation state (degraded-mode spec). One case today.
enum CrashBannerState: Equatable { case tmuxEnded }

/// A modal the session presents in response to a hardware-keyboard Cmd-shortcut
/// (Phase 4e). The VM publishes the intent; `SessionView` shows the sheet.
enum SessionSheet: String, Identifiable {
    case settings, launcher, tips, hostPicker
    var id: String { rawValue }
}

/// Drives the one MVP flow: connect → password auth → probe tmux → attach
/// control mode or degrade to a raw-PTY shell.
/// Retains the live `Connection`, `ShellSession`, and optionally `TmuxRuntime`.
@MainActor
final class ConnectionViewModel: ObservableObject {
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
    /// PaneID → live SwiftTerm view, populated by TmuxPaneContainer as panes appear.
    private var paneViews: [PaneID: TerminalView] = [:]
    private var pendingPaneBytes: [PaneID: [UInt8]] = [:]   // bytes that arrived before the view registered
    /// Panes that currently exist in the active window's visible layout.
    /// Bytes for panes NOT in this set are dropped rather than buffered (bounds memory).
    private var renderablePanes: Set<PaneID> = []

    private var promptContinuation: CheckedContinuation<Bool, Never>?

    private var connection: Connection?
    /// Last saved-host connect args, retained so `⇧⌘R` can reconnect (Phase 4e).
    private var lastSavedHost: Host?
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
        observePredictorInput(bytes)
        if let tmux {
            tmux.sendInput(bytes)
        } else {
            rawWriter?.enqueue(bytes)
        }
    }

    /// DECCKM (application-cursor-keys) state of the active pane's terminal, or
    /// false if unavailable. Best-effort SwiftTerm read (cf. the mouse-mode poll).
    private func activePaneApplicationCursor() -> Bool {
        guard let win = tmuxState?.activeWindow,
              let pane = tmuxState?.window(win)?.activePane,
              let tv = paneViews[pane] else { return false }
        return tv.getTerminal().applicationCursor
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

    func unregisterPane(_ pane: PaneID) { paneViews[pane] = nil; pendingPaneBytes[pane] = nil }

    func selectWindow(_ id: WindowID) { tmux?.selectWindow(id) }

    /// Toggle zoom on the active pane (Pad tap). No-op in raw-PTY mode.
    func zoomActivePane() { tmux?.zoomActivePane() }

    /// Esc-pill swipe-right: next tmux window (wraps). No-op with <2 windows.
    func selectNextWindow() { stepWindow(+1) }
    /// Esc-pill swipe-left: previous tmux window (wraps).
    func selectPrevWindow() { stepWindow(-1) }

    private func stepWindow(_ delta: Int) {
        guard let state = tmuxState, state.windows.count > 1,
              let active = state.activeWindow,
              let idx = state.windows.firstIndex(where: { $0.id == active }) else { return }
        let next = state.windows[(idx + delta + state.windows.count) % state.windows.count]
        selectWindow(next.id)
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
        case .find:                break   // deferred — needs a SwiftTerm scrollback-search slice
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

    func setTmuxClientSize(cols: Int, rows: Int) { tmux?.setClientSize(cols: cols, rows: rows) }

    /// Convert the container's pixel size to an approximate cell grid and push it
    /// to tmux so it re-tiles. ~8×16pt per cell for the default monospace font.
    func sendApproxClientSize(width: Double, height: Double) {
        let cols = max(1, Int(width / 8.0)); let rows = max(1, Int(height / 16.0))
        setTmuxClientSize(cols: cols, rows: rows)
    }

    // MARK: - Teardown

    /// Reset all connection and pane state. Call at the start of each connect
    /// attempt so no stale handles or buffered bytes carry over to the new session.
    private func teardown() {
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
        if let engine, let learnedStore { try? learnedStore.save(engine.state) }
        engine = nil
        tracker.reset()
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
        // Harvest raw-shell output for the predictor.
        // NOTE: TerminalScreen.makeUIView subsequently overwrites output.onBytes with
        // its render closure; raw-shell harvest is a v1 known limitation (deferred
        // until TerminalShellOutput gains a second callback slot).
        output.onBytes = { [weak self] bytes in
            self?.engine?.harvest(output: String(decoding: bytes, as: UTF8.self))
        }
        state = .shell
    }

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
        let seed = (try? AppStores.shared.deviceSeed()) ?? "neotilde-local"
        let runtime = TmuxRuntime(sessionName: tmuxSessionName(seed: seed))
        guard let startCmd = runtime.makeStartCommand() else {
            // Controller couldn't build a start command; fall through to raw PTY.
            try await openRawShell(conn: conn)
            return
        }
        runtime.onPaneBytes = { [weak self] pane, bytes in
            guard let self else { return }
            if let view = self.paneViews[pane] {
                view.feed(byteArray: bytes[...])
            } else if self.renderablePanes.contains(pane) {
                self.pendingPaneBytes[pane, default: []].append(contentsOf: bytes)
            }
            // else: pane not in visible layout — drop to prevent unbounded buffering
            // Harvest pane output for the predictor (all visible panes; not filtered by active).
            self.engine?.harvest(output: String(decoding: bytes, as: UTF8.self))
        }
        runtime.onStateChanged = { [weak self] state in
            guard let self else { return }
            let live = Set(
                (state.activeWindow.flatMap { state.window($0) }?.visibleLayout?.panes.map(\.pane)) ?? []
            )
            self.renderablePanes = live
            self.pendingPaneBytes = self.pendingPaneBytes.filter { live.contains($0.key) }
            self.tmuxState = state
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

    /// Build the session predictor unless incognito is on for this host.
    private func startPredictor(host: Host, defaults: Defaults) {
        guard !resolvePredictorIncognito(host: host, defaults: defaults) else {
            engine = nil; return
        }
        let store = AppStores.shared.predictorLearnedStore()
        learnedStore = store
        engine = PredictorEngine(learned: store.load(), seed: AppStores.shared.predictorSeed())
    }

    /// Fold outgoing bytes into the token tracker, learn committed tokens, and
    /// refresh the suggestion chips.
    private func observePredictorInput(_ bytes: [UInt8]) {
        guard engine != nil else { return }
        for committed in tracker.observe(bytes) {
            engine?.record(committed.token, after: committed.previous)
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
                let conn = try await NeotildeSSHCoreFFI.connect(
                    addr: addr, allowLegacy: false, allowDeprecated: false, verifier: verifier)
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
                let allow = resolveTmuxAttemptControlMode(host: savedHost, defaults: defaults2)
                let probe = allow ? await probeTmuxVersion(conn: conn) : nil
                switch tmuxLaunchDecision(attemptControlMode: allow, versionProbe: probe) {
                case .attach:
                    try await attachTmux(conn: conn)
                case .degrade(let reason):
                    degraded = reason
                    try await openRawShell(conn: conn)
                }
            } catch ConnectError.HostKeyRejected {
                state = .failed("Host key not trusted")
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
                let conn = try await NeotildeSSHCoreFFI.connect(
                    addr: addr, allowLegacy: false, allowDeprecated: false, verifier: verifier)
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
                let allow = resolveTmuxAttemptControlMode(host: hostRecord, defaults: defaults2)
                let probe = allow ? await probeTmuxVersion(conn: conn) : nil
                switch tmuxLaunchDecision(attemptControlMode: allow, versionProbe: probe) {
                case .attach:
                    try await attachTmux(conn: conn)
                case .degrade(let reason):
                    degraded = reason
                    try await openRawShell(conn: conn)
                }
            } catch ConnectError.HostKeyRejected {
                state = .failed("Host key not trusted")
            } catch {
                state = .failed(String(describing: error))
            }
        }
    }
}
