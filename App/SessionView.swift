// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import SemicolynKit

/// `Host` isn't `Identifiable`; this thin wrapper lets `.fullScreenCover(item:)`
/// present a nested session for an ssh:// quick-connect target (mirrors the wrapper
/// `HostListView` uses to open a saved host).
private struct IdentifiableHost: Identifiable {
    let id: UUID
    let host: Host
    init(_ host: Host) { self.id = host.id; self.host = host }
}

/// Presents a live SSH session for a saved `Host`. Resolves credentials in the
/// same precedence the connect path uses (`ConnectionViewModel.authenticate`):
/// a host with a usable publickey identity connects via that key with no prompt;
/// otherwise a stored password auto-connects; only a host with neither prompts
/// the user for a password.
struct SessionView: View {
    let host: Host

    @StateObject private var vm = ConnectionViewModel()
    @StateObject private var hardwareKeyboard = HardwareKeyboardMonitor()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.scenePhase) private var scenePhase

    /// Password loaded from the Keychain-backed secret store, or entered by the
    /// user when no stored secret exists.
    @State private var password: String = ""
    /// True once we have looked up the stored secret (so we don't connect twice).
    @State private var credentialsResolved = false
    /// Set to true when the stored secret lookup failed to find a password,
    /// indicating the user must provide one manually.
    @State private var needsPasswordEntry = false
    /// True while `resolveCredentials()` has not yet run (first `onAppear` not
    /// yet fired). Guards against showing a misleading "Connecting to …" spinner
    /// before we know whether a stored credential exists.
    @State private var resolving = true
    /// Set when the user confirms an ssh:// link tap; drives a nested session cover.
    @State private var quickConnectHost: IdentifiableHost?
    /// Drives the "Disconnect from <host>?" confirmation dialog.
    @State private var confirmingDisconnect = false
    /// Whether the debug log panel is enabled (Settings → Diagnostics; off by default).
    @AppStorage(DiagnosticsSettingsView.showDebugPanelKey) private var diagnosticsPanelEnabled = false
    /// Transient: whether the panel is currently expanded (only meaningful when enabled).
    @State private var showDebugPanel = false

    var body: some View {
        Group {
            if case .shell = vm.state {
                if let tmuxState = vm.tmuxState {
                    VStack(spacing: 0) {
                        WindowTabStrip(windows: tmuxState.windows, active: tmuxState.activeWindow,
                                       onSelect: { vm.selectWindow($0) })
                        TmuxPaneContainer(
                            state: tmuxState,
                            register: { vm.registerPane($0, $1) },
                            unregister: { vm.unregisterPane($0) },
                            send: { vm.terminalKeyboardInput($0) },
                            cursorSend: { vm.sendTerminalInput($0) },
                            theme: theme,
                            settings: AppStores.shared.terminalSettings.settings,
                            osc52Allowed: vm.osc52Allowed,
                            onTitle: { [weak vm] view, t in vm?.setTmuxTitle(from: view, t) },
                            onTmuxResize: { [weak vm] cols, rows in vm?.setTmuxClientSize(cols: cols, rows: rows) },
                            onSSHLink: { [weak vm] url in vm?.presentSSHLink(url) })
                        // Client size is reported by the pane container's layout pass
                        // (bounds ÷ measured cell) via onTmuxResize — no coarse estimate.
                    }
                    // NOTE: the terminal must respect the bottom safe area so the
                    // keybar's `.safeAreaInset` below genuinely reserves space and the
                    // terminal ends ABOVE the keybar (not under it). Only the keybar's
                    // background extends into the home-indicator strip (see the inset).
                    .overlay(alignment: .top) {
                        if let reason = vm.degraded {
                            DegradedBanner(reason: reason) { vm.degraded = nil }
                                .transition(.move(edge: .top).combined(with: .opacity))
                                .task {
                                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                                    vm.degraded = nil
                                }
                        }
                    }
                    .animation(.easeInOut, value: vm.degraded)
                    .overlay(alignment: .top) {
                        if let reason = vm.moshFallback {
                            MoshFallbackBanner(reason: reason) { vm.moshFallback = nil }
                                .transition(.move(edge: .top).combined(with: .opacity))
                                // Persist until the user dismisses (tap). No auto-dismiss:
                                // it carries the real mosh failure reason, which the user
                                // needs time to read, and the 4s timer used to cancel early
                                // when attachSSHShell replaced this view (the "brief flash").
                        }
                    }
                    .animation(.easeInOut, value: vm.moshFallback)
                    .overlay(alignment: .top) {
                        if vm.crashBanner != nil {
                            CrashBanner(
                                onReattach: { vm.reattachTmux() },
                                onStartNew: { vm.startNewTmux() },
                                onDismiss: { vm.dismissCrashBanner() })
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .animation(.easeInOut, value: vm.crashBanner)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        VStack(spacing: 0) {
                            PredictorStripView(vm: vm, predictorVM: vm.predictorVM)
                            KeybarView(keybarSettings: AppStores.shared.keybarSettings, vm: vm,
                                       hardwareKeyboardConnected: hardwareKeyboard.isConnected)
                        }
                        // Extend only the keybar's panel background into the
                        // home-indicator strip; the keys stay within the safe area.
                        .background(Color(theme.surface.panel).ignoresSafeArea(edges: .bottom))
                    }
                } else {
                    TerminalScreen(send: { [weak vm] bytes in vm?.terminalKeyboardInput(bytes) },
                                   cursorSend: { [weak vm] bytes in vm?.sendTerminalInput(bytes) },
                                   output: vm.output,
                                   session: vm.session,
                                   // Mosh has no ShellSession, so its debounced resize routes
                                   // through an explicit sink → setMoshClientSize → the bridge's
                                   // shared winsize + SIGWINCH. Raw SSH leaves this nil and uses
                                   // session?.resize. (Note: MoshSession is currently seeded at
                                   // 80×24 and corrected by the first resize event here; to avoid
                                   // that brief initial reflow we could plumb the real grid size
                                   // into attachMoshIfPossible before creating the session — a
                                   // future refinement, see item #5 Q2(b).)
                                   onResize: vm.isMoshActive
                                       ? { [weak vm] cols, rows in vm?.setMoshClientSize(cols: cols, rows: rows) }
                                       : nil,
                                   theme: theme,
                                   osc52Allowed: vm.osc52Allowed,
                                   onTitle: { [weak vm] t in vm?.terminalTitle = t },
                                   onSSHLink: { [weak vm] url in vm?.presentSSHLink(url) })
                        // Respect the bottom safe area so the keybar inset reserves
                        // space and the terminal ends above it (see the tmux branch).
                        .overlay(alignment: .top) {
                            if let reason = vm.degraded {
                                DegradedBanner(reason: reason) { vm.degraded = nil }
                                    .transition(.move(edge: .top).combined(with: .opacity))
                                    .task {
                                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                                        vm.degraded = nil
                                    }
                            }
                        }
                        .animation(.easeInOut, value: vm.degraded)
                        .overlay(alignment: .top) {
                            if let reason = vm.moshFallback {
                                MoshFallbackBanner(reason: reason) { vm.moshFallback = nil }
                                    .transition(.move(edge: .top).combined(with: .opacity))
                                    .task {
                                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                                        vm.moshFallback = nil
                                    }
                            }
                        }
                        .animation(.easeInOut, value: vm.moshFallback)
                        .overlay(alignment: .top) {
                            if vm.crashBanner != nil {
                                CrashBanner(
                                    onReattach: { vm.reattachTmux() },
                                    onStartNew: { vm.startNewTmux() },
                                    onDismiss: { vm.dismissCrashBanner() })
                                    .transition(.move(edge: .top).combined(with: .opacity))
                            }
                        }
                        .animation(.easeInOut, value: vm.crashBanner)
                        .safeAreaInset(edge: .bottom, spacing: 0) {
                            VStack(spacing: 0) {
                                PredictorStripView(vm: vm, predictorVM: vm.predictorVM)
                                KeybarView(keybarSettings: AppStores.shared.keybarSettings, vm: vm,
                                       hardwareKeyboardConnected: hardwareKeyboard.isConnected)
                            }
                            // Extend only the keybar's panel background into the
                            // home-indicator strip; the keys stay within the safe area.
                            .background(Color(theme.surface.panel).ignoresSafeArea(edges: .bottom))
                        }
                }
            } else if resolving {
                // Resolution not yet run — show a neutral spinner with no label
                // so the "Connecting to <host>…" text never flashes before we
                // know which path to take.
                ProgressView()
            } else if needsPasswordEntry {
                passwordPrompt
            } else {
                statusView
            }
        }
        // Connected-state Disconnect affordance: a small top-trailing control (the
        // connected view has no nav bar). Confirms before tearing down so a session
        // isn't lost by an accidental tap. Shown only while a live shell is up.
        .overlay(alignment: .topTrailing) {
            if case .shell = vm.state {
                Button {
                    confirmingDisconnect = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Color(theme.text.secondary))
                        .padding(8)
                        .accessibilityLabel("Disconnect")
                }
                .buttonStyle(.plain)
                .padding(.top, 4).padding(.trailing, 6)
            }
        }
        .confirmationDialog("Disconnect from \(host.label)?",
                            isPresented: $confirmingDisconnect, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) { vm.disconnect() }
            Button("Cancel", role: .cancel) {}
        }
        // DIAGNOSTIC: a 🐞 toggle (top-leading) opens a scrollable debug log panel
        // with Copy/Clear, capturing the connection/tmux/input-routing trace. Gated
        // behind Settings → Diagnostics → "Show debug log panel" (off by default).
        .overlay(alignment: .topLeading) {
            if case .shell = vm.state, diagnosticsPanelEnabled {
                Button { showDebugPanel.toggle() } label: {
                    Image(systemName: "ladybug.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.green)
                        .padding(6)
                        .background(Color.black.opacity(0.6), in: Circle())
                }
                .padding(.leading, 6).padding(.top, 2)
            }
        }
        .overlay(alignment: .top) {
            if showDebugPanel {
                DebugLogPanel(onClose: { showDebugPanel = false })
                    .padding(.top, 40)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        // When a disconnect (or a terminal failure the user acknowledges) flips the
        // session out of the shell, leave the session screen back to the host list.
        .onChange(of: vm.state) { _, newState in
            if case .idle = newState { dismiss() }
        }
        // Host-key prompt sheet — mirrors ConnectView exactly.
        // `onDismiss` fails closed: if the sheet is dismissed without an explicit
        // button tap, treat it as rejection so the continuation is never leaked.
        .sheet(item: $vm.pendingPrompt, onDismiss: { vm.resolvePrompt(false) }) { prompt in
            Group {
                switch prompt {
                case let .firstTrust(hostLabel, keyType, offered):
                    FirstTrustModal(hostLabel: hostLabel, keyType: keyType, offered: offered,
                                    onDecision: { vm.resolvePrompt($0) })
                case let .mismatch(hostLabel, keyType, stored, offered):
                    MismatchModal(hostLabel: hostLabel, keyType: keyType, stored: stored,
                                  offered: offered, onDecision: { vm.resolvePrompt($0) })
                }
            }
            .interactiveDismissDisabled()
        }
        // Hardware-keyboard Cmd-shortcuts — registered only while in the shell so
        // they never shadow text editing on the connect/password screens (4e).
        .background {
            if case .shell = vm.state { KeyboardCommandsView(vm: vm) }
        }
        .sheet(item: $vm.presentedSheet) { sheet in
            sessionSheet(sheet)
        }
        // Confirmed ssh:// link → open a nested session for the (found-or-created) host.
        .fullScreenCover(item: $quickConnectHost) { wrapper in
            SessionView(host: wrapper.host)
        }
        .onAppear {
            resolveCredentials()
        }
        // Flush learned predictor state when the app backgrounds, so a session
        // that gets backgrounded and killed doesn't lose what it learned (only a
        // clean teardown flushed before). No-op when the predictor is off.
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { vm.flushPredictor() }
        }
    }

    /// The modal a Cmd-shortcut asked for (Phase 4e).
    @ViewBuilder private func sessionSheet(_ sheet: SessionSheet) -> some View {
        switch sheet {
        case .settings:
            KeybarSettingsSheet(store: AppStores.shared.keybarSettings)
        case .launcher:
            NavigationStack { MacroLibraryView(store: AppStores.shared.keybarSettings) }
        case .tips:
            NavigationStack { TipsView() }
        case .hostPicker:
            HostListView()
        case let .quickConnect(target):
            QuickConnectSheet(
                target: target,
                onConnect: {
                    let host = try? vm.hostForSSHTarget(target)
                    vm.presentedSheet = nil
                    if let host { quickConnectHost = IdentifiableHost(host) }
                },
                onCancel: { vm.presentedSheet = nil })
        }
    }

    // MARK: - Credential resolution

    /// Attempts to load the stored password from the Keychain secret store.
    /// If found, connects immediately. If not, shows the manual password prompt.
    private func resolveCredentials() {
        guard !credentialsResolved else { return }
        defer { resolving = false }
        credentialsResolved = true

        let defaults = (try? AppStores.shared.hosts.defaults()) ?? Defaults()
        let storedPassword = storedPassword()
        // Mirror the connect-path auth precedence so a key-configured host never
        // gets stuck on the password prompt (the "key auth coming in 2b" regression).
        switch credentialResolution(hasUsableKey: hostHasUsableKey(defaults: defaults),
                                     hasStoredPassword: storedPassword != nil) {
        case .connectWithKey:
            // `authenticate` uses the resolved identity's key and ignores the
            // password argument, so an empty password is correct here.
            vm.connect(savedHost: host, password: "")
        case .connectWithStoredPassword:
            password = storedPassword ?? ""
            vm.connect(savedHost: host, password: password)
        case .promptForPassword:
            needsPasswordEntry = true
        }
    }

    /// The host's non-empty stored password, or nil (absent, unreadable, or empty).
    private func storedPassword() -> String? {
        guard let passwordID = host.passwordRef.value,
              let data = try? AppStores.shared.secrets.getSecret(.password(id: passwordID))
        else { return nil }
        let stored = String(decoding: data, as: UTF8.self)
        return stored.isEmpty ? nil : stored
    }

    /// True if the host resolves to an identity whose private key is available on
    /// this device — the same check `ConnectionViewModel.authenticate` gates on.
    /// A Keychain read error is treated as "no usable key" here (the connect path
    /// re-reads and surfaces a genuine failure), so a transient error only means we
    /// fall back to the password prompt rather than silently blocking.
    private func hostHasUsableKey(defaults: Defaults) -> Bool {
        guard let identityID = resolveIdentities(host: host, defaults: defaults).first else {
            return false
        }
        // privateKeyOpenSSH returns String? (nil = absent); `try?` collapses a read
        // error to nil too. Either nil → no usable key on this device.
        let key = try? AppStores.shared.identities.privateKeyOpenSSH(for: identityID)
        return (key ?? nil) != nil
    }

    // MARK: - Password prompt

    /// Shown when the host has no stored `passwordRef` secret.
    private var passwordPrompt: some View {
        NavigationStack {
            Form {
                Section {
                    Text(host.label)
                        .font(.headline)
                        .foregroundStyle(Color(theme.text.primary))
                    Text(host.hostName)
                        .font(.caption)
                        .foregroundStyle(Color(theme.text.secondary))
                }

                Section("Authentication") {
                    SecureField("Password", text: $password)
                    // This prompt only appears when the host has no usable key. Key
                    // auth is used automatically for hosts with an assigned identity.
                    Text("No SSH key assigned to this host — enter a password, or assign an identity in the host editor to use key auth.")
                        .font(.caption)
                        .foregroundStyle(Color(theme.text.secondary))
                }

                Section {
                    Button {
                        credentialsResolved = true
                        needsPasswordEntry = false
                        vm.connect(savedHost: host, password: password)
                    } label: {
                        if vm.state == .connecting {
                            ProgressView()
                        } else {
                            Text("Connect")
                        }
                    }
                    .disabled(password.isEmpty || vm.state == .connecting)
                }

                if case .failed(let message) = vm.state {
                    Section {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Connect")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    // MARK: - Status / connecting / error

    /// Shown while connecting or on failure (when not in the password prompt).
    /// Wraps content in a `NavigationStack` so a Close button is always reachable —
    /// unlike `passwordPrompt`, this view may be shown without any surrounding nav host.
    private var statusView: some View {
        NavigationStack {
            VStack(spacing: 20) {
                switch vm.state {
                case .idle, .connecting:
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("Connecting to \(host.label)…")
                        .foregroundStyle(Color(theme.text.secondary))
                case .failed(let message):
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(Color(theme.state.broken))
                    Text(message)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Color(theme.text.primary))
                        .padding(.horizontal, 32)
                    HStack(spacing: 16) {
                        Button("Close") { dismiss() }
                            .buttonStyle(.bordered)
                        Button("Retry") {
                            vm.connect(savedHost: host, password: password)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color(theme.accent.primary))
                    }
                case .shell:
                    // Handled in the outer `Group` — this branch is unreachable here.
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}
