// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import SwiftTerm
import NeotildeKit
import NeotildeSSHCoreFFI

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
    /// Non-nil when we fell back from control mode; consumed by Task 6 to show
    /// an amber banner explaining why tmux wasn't used.
    @Published var degraded: DegradeReason?
    /// Non-nil while attached to tmux control mode; nil in raw-PTY mode.
    @Published var tmuxState: TmuxSessionState?
    /// PaneID → live SwiftTerm view, populated by TmuxPaneContainer as panes appear.
    private var paneViews: [PaneID: TerminalView] = [:]
    private var pendingPaneBytes: [PaneID: [UInt8]] = [:]   // bytes that arrived before the view registered
    /// Panes that currently exist in the active window's visible layout.
    /// Bytes for panes NOT in this set are dropped rather than buffered (bounds memory).
    private var renderablePanes: Set<PaneID> = []

    private var promptContinuation: CheckedContinuation<Bool, Never>?

    private var connection: Connection?
    private(set) var session: ShellSession?
    /// Serializes raw-PTY keystroke writes (FIFO under channel back-pressure).
    /// Only used in raw mode; tmux mode writes through `TmuxRuntime`'s own writer.
    private var rawWriter: SerialByteWriter?
    /// Non-nil while a tmux control-mode session is active.
    private var tmux: TmuxRuntime?
    /// Shared output sink; the terminal view wires `onBytes` to render into itself.
    let output = TerminalShellOutput()

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

    /// Route terminal keystrokes: through tmux `send-keys` when control mode is
    /// attached, else straight to the raw-PTY channel.
    func sendTerminalInput(_ bytes: [UInt8]) {
        if let tmux {
            tmux.sendInput(bytes)
        } else {
            rawWriter?.enqueue(bytes)
        }
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
        tmux = nil
        rawWriter?.finish()
        rawWriter = nil
        session = nil
        connection = nil
        tmuxState = nil
        paneViews.removeAll()
        pendingPaneBytes.removeAll()
        renderablePanes.removeAll()
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
        state = .shell
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
        }
        runtime.onStateChanged = { [weak self] state in
            guard let self else { return }
            let live = Set(
                (state.activeWindow.flatMap { state.window($0) }?.visibleLayout?.panes.map(\.pane)) ?? []
            )
            self.renderablePanes = live
            self.pendingPaneBytes = self.pendingPaneBytes.filter { live.contains($0.key) }
            self.tmuxState = state
        }
        runtime.onExit = { [weak self] reason in self?.state = .failed(reason ?? "tmux session ended") }
        let sink = TerminalShellOutput()
        sink.onBytes = { [weak runtime] bytes in runtime?.ingest(bytes) }
        sink.onExit = { [weak self] exit in
            self?.state = .failed(exit.error ?? "Session closed")
        }
        let sess = try await conn.openExec(command: startCmd, term: "xterm-256color",
                                           cols: 80, rows: 24, output: sink)
        runtime.session = sess
        connection = conn
        session = sess
        self.tmux = runtime   // retain to keep control mode alive
        state = .shell
    }

    // MARK: - Connect (saved host)

    /// Connect from a saved `Host` record, using its resolved config and a
    /// caller-supplied password. Does NOT create or modify any host record
    /// (contrast with `connect(host:port:user:password:)` which calls
    /// `findOrCreateHost`). Throws a user-facing `.failed` state if the user
    /// field cannot be resolved.
    func connect(savedHost: Host, password: String) {
        if state == .connecting || state == .shell { return }
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
