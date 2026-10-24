// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import SemicolynKit

/// Settings > Connection Defaults: the singleton `Defaults` record, i.e. the values
/// every host uses for a field it leaves blank.
///
/// Live apply, like every other Settings screen: each change is written straight to
/// the store (`DefaultsEditorViewModel`), with no Save or Cancel and no nested
/// NavigationStack, so Back returns to Settings. Plain headed sections.
///
/// An unset row reads "Default (X)" (pickers) or "Default: X" (text fields), X being
/// the built-in value. Swipe-left on a set row resets it ("Clear override").
///
/// Options that are stored but not applied yet (`UnwiredOptions`) are hidden. Jump
/// chain and port forwarding have no global default and are not listed here.
///
/// NOTE: This is a standalone view, NOT an extension of `HostEditorView`. It reuses
/// the pure mapper functions from `InheritedBinding.swift` (only).
struct DefaultsEditorView: View {
    @StateObject private var vm = DefaultsEditorViewModel()
    @Environment(\.theme) private var theme

    private var builtIn: InheritedFallbacks { vm.fallbacks }

    var body: some View {
        List {
            basicsSection
            signInSection
            connectionSection
            keepAliveSection
            moshSection
            if UnwiredOptions.tailscale {
                tailscaleSection
            }
            tmuxSection
            privacySection
        }
        .navigationTitle("Connection Defaults")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Couldn't save", isPresented: Binding(
            get: { vm.saveError != nil },
            set: { if !$0 { vm.saveError = nil } }
        )) {
            Button("OK", role: .cancel) { InputClickFeedback.play(); vm.saveError = nil }
        } message: {
            Text(vm.saveError ?? "")
        }
    }

    // MARK: - Shared row helpers

    /// A text value with a caption line under it (the caption explains the row).
    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(Color(theme.text.secondary))
    }

    // MARK: - Basics (user, port)

    private var basicsSection: some View {
        Section {
            // user, Inherited<String>; no built-in fallback
            LabeledContent {
                TextField(
                    builtIn.userPlaceholder,
                    text: Binding(
                        get: { inheritedStringToText(vm.defaults.user) },
                        set: { vm.defaults.user = textToInheritedString($0) }
                    )
                )
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .multilineTextAlignment(.trailing)
            } label: {
                Text("User")
                    .foregroundStyle(Color(theme.text.primary))
            }
            .swipeActions {
                if case .explicit = vm.defaults.user {
                    Button("Clear override") { vm.defaults.user = .inherit }
                        .tint(Color(theme.accent.primary))
                }
            }

            // port, Inherited<Int>; built-in fallback: 22
            LabeledContent {
                TextField(
                    defaultPlaceholder(String(builtIn.port)),
                    text: Binding(
                        get: { inheritedIntToText(vm.defaults.port) },
                        set: { vm.defaults.port = textToInheritedInt($0) }
                    )
                )
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
            } label: {
                Text("Port")
                    .foregroundStyle(Color(theme.text.primary))
            }
            .swipeActions {
                if case .explicit = vm.defaults.port {
                    Button("Clear override") { vm.defaults.port = .inherit }
                        .tint(Color(theme.accent.primary))
                }
            }
        } header: {
            Text("Basics")
        } footer: {
            Text("Hosts use these values unless they set their own.")
        }
    }

    // MARK: - Connection (connection type)

    /// The connection type in effect for a host that leaves it blank.
    private var effectiveTransport: Transport {
        vm.defaults.transport.value ?? builtIn.transport
    }

    private var connectionSection: some View {
        Section {
            Picker(selection: Binding(
                get: {
                    switch vm.defaults.transport {
                    case .inherit: return "default"
                    case .explicit(let t): return t?.rawValue ?? "default"
                    }
                },
                set: { (sel: String) in
                    vm.defaults.transport = (sel == "default") ? .inherit : .explicit(Transport(rawValue: sel))
                }
            )) {
                Text(defaultChoiceLabel(builtIn.transport.displayName)).tag("default")
                ForEach(Transport.allCases, id: \.rawValue) { t in
                    Text(t.displayName).tag(t.rawValue)
                }
            } label: {
                Text("Connection type")
                    .foregroundStyle(Color(theme.text.primary))
            }
            .swipeActions {
                if case .explicit = vm.defaults.transport {
                    Button("Clear override") { vm.defaults.transport = .inherit }
                        .tint(Color(theme.accent.primary))
                }
            }

            if UnwiredOptions.compression { compressionRow }
            if UnwiredOptions.agentForwarding { forwardAgentRow }
            if UnwiredOptions.hostKeyChecking { shkRow }
            if UnwiredOptions.preferredAuth { preferredAuthSection }
        } header: {
            Text("Connection")
        } footer: {
            Text(effectiveTransport.summary + " Leave on SSH if unsure.")
        }
    }

    // MARK: - SSH keep-alive

    private var keepAliveSection: some View {
        Section {
            // serverAliveInterval, Inherited<Int>; built-in fallback: 30
            LabeledContent {
                TextField(
                    defaultPlaceholder(String(builtIn.keepAliveInterval)),
                    text: Binding(
                        get: { inheritedIntToText(vm.defaults.serverAliveInterval) },
                        set: { vm.defaults.serverAliveInterval = textToInheritedInt($0, minimum: 0) }
                    )
                )
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
            } label: {
                Text("Every (seconds)")
                    .foregroundStyle(Color(theme.text.primary))
            }
            .swipeActions {
                if case .explicit = vm.defaults.serverAliveInterval {
                    Button("Clear override") { vm.defaults.serverAliveInterval = .inherit }
                        .tint(Color(theme.accent.primary))
                }
            }

            // serverAliveCountMax, Inherited<Int>; built-in fallback: 3
            LabeledContent {
                TextField(
                    defaultPlaceholder(String(builtIn.keepAliveRetries)),
                    text: Binding(
                        get: { inheritedIntToText(vm.defaults.serverAliveCountMax) },
                        set: { vm.defaults.serverAliveCountMax = textToInheritedInt($0, minimum: 0) }
                    )
                )
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
            } label: {
                Text("Missed replies before disconnect")
                    .foregroundStyle(Color(theme.text.primary))
            }
            .swipeActions {
                if case .explicit = vm.defaults.serverAliveCountMax {
                    Button("Clear override") { vm.defaults.serverAliveCountMax = .inherit }
                        .tint(Color(theme.accent.primary))
                }
            }
        } header: {
            Text("SSH keep-alive")
        } footer: {
            Text("Sends a small signal so idle connections don't drop. For Mosh and Eternal Terminal it is only used while setting up the connection.")
        }
    }

    // MARK: - Hidden until wired (UnwiredOptions)

    private var compressionRow: some View {
        Picker(selection: Binding(
            get: { inheritedBoolToSelection(vm.defaults.compression) },
            set: { vm.defaults.compression = selectionToInheritedBool($0) }
        )) {
            Text(defaultChoiceLabel("Off")).tag(Bool?.none)
            Text("On").tag(Bool?.some(true))
            Text("Off").tag(Bool?.some(false))
        } label: {
            Text("Compression")
                .foregroundStyle(Color(theme.text.primary))
        }
        .swipeActions {
            if case .explicit = vm.defaults.compression {
                Button("Clear override") { vm.defaults.compression = .inherit }
                    .tint(Color(theme.accent.primary))
            }
        }
    }

    private var forwardAgentRow: some View {
        Picker(selection: Binding(
            get: { inheritedBoolToSelection(vm.defaults.forwardAgent) },
            set: { vm.defaults.forwardAgent = selectionToInheritedBool($0) }
        )) {
            Text(defaultChoiceLabel("Off")).tag(Bool?.none)
            Text("On").tag(Bool?.some(true))
            Text("Off").tag(Bool?.some(false))
        } label: {
            Text("Agent forwarding")
                .foregroundStyle(Color(theme.text.primary))
        }
        .swipeActions {
            if case .explicit = vm.defaults.forwardAgent {
                Button("Clear override") { vm.defaults.forwardAgent = .inherit }
                    .tint(Color(theme.accent.primary))
            }
        }
    }

    private var shkRow: some View {
        Picker(selection: Binding(
            get: { inheritedSHKCToSelection(vm.defaults.strictHostKeyChecking) },
            set: { vm.defaults.strictHostKeyChecking = selectionToInheritedSHKC($0) }
        )) {
            Text(defaultChoiceLabel("accept-new")).tag(StrictHostKeyChecking?.none)
            Text("yes").tag(StrictHostKeyChecking?.some(.yes))
            Text("accept-new").tag(StrictHostKeyChecking?.some(.acceptNew))
            Text("ask").tag(StrictHostKeyChecking?.some(.ask))
            Text("no").tag(StrictHostKeyChecking?.some(.no))
        } label: {
            Text("Host key checking")
                .foregroundStyle(Color(theme.text.primary))
        }
        .swipeActions {
            if case .explicit = vm.defaults.strictHostKeyChecking {
                Button("Clear override") { vm.defaults.strictHostKeyChecking = .inherit }
                    .tint(Color(theme.accent.primary))
            }
        }
    }

    /// Per-method toggles for `preferredAuthentications`. Toggling any method promotes
    /// the field to `.explicit`.
    private var preferredAuthSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Preferred auth")
                    .foregroundStyle(Color(theme.text.primary))
                Spacer()
                if case .explicit = vm.defaults.preferredAuthentications {
                    Button("Clear") { InputClickFeedback.play(); vm.defaults.preferredAuthentications = .inherit }
                        .font(.caption)
                        .foregroundStyle(Color(theme.accent.primary))
                }
            }

            ForEach([AuthMethod.publicKey, .keyboardInteractive, .password], id: \.self) { method in
                let methodLabel: String = {
                    switch method {
                    case .publicKey: return "Public key"
                    case .password: return "Password"
                    case .keyboardInteractive: return "Keyboard-interactive"
                    }
                }()
                let isActive: Bool =
                    vm.defaults.preferredAuthentications.value?.contains(method) ?? false

                Toggle(isOn: Binding(
                    get: { isActive },
                    set: { newValue in
                        var current: Set<AuthMethod> =
                            inheritedAuthMethodsToSelection(vm.defaults.preferredAuthentications) ?? Set()
                        if newValue { current.insert(method) } else { current.remove(method) }
                        vm.defaults.preferredAuthentications = selectionToInheritedAuthMethods(current)
                    }
                )) {
                    Text(methodLabel)
                        .font(.subheadline)
                        .foregroundStyle(Color(theme.text.primary))
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var tailscaleSection: some View {
        Section("Tailscale") {
            Toggle(isOn: Binding(
                get: { vm.defaults.tailscale.value?.required ?? false },
                set: { newRequired in
                    var cfg = vm.defaults.tailscale.value ?? TailscaleConfig(required: false)
                    cfg.required = newRequired
                    vm.defaults.tailscale = .explicit(cfg)
                }
            )) {
                Text("Require Tailscale")
                    .foregroundStyle(Color(theme.text.primary))
            }
            .swipeActions {
                if case .explicit = vm.defaults.tailscale {
                    Button("Clear override") { vm.defaults.tailscale = .inherit }
                        .tint(Color(theme.accent.primary))
                }
            }

            if vm.defaults.tailscale.value?.required == true {
                LabeledContent {
                    TextField(
                        "e.g. mycompany.ts.net",
                        text: Binding(
                            get: { vm.defaults.tailscale.value?.tailnet ?? "" },
                            set: { newTailnet in
                                var cfg = vm.defaults.tailscale.value ?? TailscaleConfig(required: true)
                                cfg.tailnet = newTailnet.isEmpty ? nil : newTailnet
                                vm.defaults.tailscale = .explicit(cfg)
                            }
                        )
                    )
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                } label: {
                    Text("Tailnet")
                        .foregroundStyle(Color(theme.text.primary))
                }
            }
        }
    }

    // MARK: - Mosh

    /// The Defaults Mosh config to edit. A new one is created with `enabled: false`:
    /// these settings are only "used by hosts set to Mosh" and must never imply the
    /// Mosh transport (`resolveTransport` ignores a Defaults `enabled` flag anyway).
    private var moshConfig: MoshConfig {
        vm.defaults.mosh.value ?? MoshConfig(enabled: false)
    }

    private var moshSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent {
                    TextField(
                        "e.g. /usr/local/bin/mosh-server",
                        text: Binding(
                            get: { vm.defaults.mosh.value?.serverPath ?? "" },
                            set: { newPath in
                                var cfg = moshConfig
                                cfg.serverPath = newPath.isEmpty ? nil : newPath
                                vm.defaults.mosh = .explicit(cfg)
                            }
                        )
                    )
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .multilineTextAlignment(.trailing)
                } label: {
                    Text("Server path")
                        .foregroundStyle(Color(theme.text.primary))
                }
                caption("Only needed if mosh-server isn't found automatically.")
            }

            VStack(alignment: .leading, spacing: 4) {
                LabeledContent {
                    HStack(spacing: 8) {
                        TextField(
                            "From",
                            text: Binding(
                                get: {
                                    if let range = vm.defaults.mosh.value?.udpPortRange,
                                       range.count >= 2 { return String(range[0]) }
                                    return ""
                                },
                                set: { newLo in
                                    var cfg = moshConfig
                                    let lo = Int(newLo) ?? 0
                                    let hi = (cfg.udpPortRange?.count ?? 0) >= 2
                                        ? cfg.udpPortRange![1] : 0
                                    cfg.udpPortRange = (lo > 0 || hi > 0) ? [lo, hi] : nil
                                    vm.defaults.mosh = .explicit(cfg)
                                }
                            )
                        )
                        .keyboardType(.numberPad)
                        .frame(maxWidth: .infinity)

                        Text("to")
                            .foregroundStyle(Color(theme.text.secondary))

                        TextField(
                            "To",
                            text: Binding(
                                get: {
                                    if let range = vm.defaults.mosh.value?.udpPortRange,
                                       range.count >= 2 { return String(range[1]) }
                                    return ""
                                },
                                set: { newHi in
                                    var cfg = moshConfig
                                    let lo = (cfg.udpPortRange?.count ?? 0) >= 2
                                        ? cfg.udpPortRange![0] : 0
                                    let hi = Int(newHi) ?? 0
                                    cfg.udpPortRange = (lo > 0 || hi > 0) ? [lo, hi] : nil
                                    vm.defaults.mosh = .explicit(cfg)
                                }
                            )
                        )
                        .keyboardType(.numberPad)
                        .frame(maxWidth: .infinity)
                    }
                } label: {
                    Text("UDP ports")
                        .foregroundStyle(Color(theme.text.primary))
                }
                caption("Leave blank unless your firewall needs a fixed range, for example 60000 to 61000.")
            }

            VStack(alignment: .leading, spacing: 4) {
                // "Default" already sends adaptive, so the two are one choice.
                Picker(selection: Binding(
                    get: { moshLocalEchoSelection(vm.defaults.mosh.value?.predictionMode) },
                    set: { newMode in
                        var cfg = moshConfig
                        cfg.predictionMode = newMode
                        vm.defaults.mosh = .explicit(cfg)
                    }
                )) {
                    Text("Adaptive (default)").tag(MoshPredictionMode?.none)
                    Text("Always").tag(MoshPredictionMode?.some(.always))
                    Text("Never").tag(MoshPredictionMode?.some(.never))
                    Text("Experimental").tag(MoshPredictionMode?.some(.experimental))
                } label: {
                    Text("Local echo")
                        .foregroundStyle(Color(theme.text.primary))
                }
                caption("Shows your typing before the server confirms it. Adaptive does this only on slow connections.")
            }
        } header: {
            Text("Mosh")
        } footer: {
            Text("Used by hosts set to Mosh.")
        }
    }

    // MARK: - tmux

    private var tmuxSection: some View {
        Section {
            // Use tmux, built-in fallback: true. Gestures drive plain tmux over
            // SSH/Mosh/ET alike.
            Toggle(isOn: Binding(
                get: { vm.defaults.semicolyn.value?.tmux?.useTmux ?? true },
                set: { newUseTmux in
                    var cfg = vm.defaults.semicolyn.value ?? SemicolynConfig()
                    var tmux = cfg.tmux ?? TmuxConfig()
                    tmux.useTmux = newUseTmux
                    cfg.tmux = tmux
                    vm.defaults.semicolyn = .explicit(cfg)
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Use tmux")
                        .foregroundStyle(Color(theme.text.primary))
                    caption(useTmuxCaption)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                LabeledContent {
                    TextField(
                        defaultPlaceholder(builtIn.tmuxSessionName),
                        text: Binding(
                            get: { vm.defaults.semicolyn.value?.tmux?.sessionName ?? "" },
                            set: { newName in
                                var cfg = vm.defaults.semicolyn.value ?? SemicolynConfig()
                                var tmux = cfg.tmux ?? TmuxConfig()
                                tmux.sessionName = newName.isEmpty ? nil : newName
                                cfg.tmux = tmux
                                vm.defaults.semicolyn = .explicit(cfg)
                            }
                        )
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
                } label: {
                    Text("Session name")
                        .foregroundStyle(Color(theme.text.primary))
                }
                caption(tmuxSessionNameCaption)
            }
            .swipeActions {
                if vm.defaults.semicolyn.value?.tmux?.sessionName != nil {
                    Button("Clear override") {
                        var cfg = vm.defaults.semicolyn.value ?? SemicolynConfig()
                        var tmux = cfg.tmux ?? TmuxConfig()
                        tmux.sessionName = nil
                        cfg.tmux = tmux
                        vm.defaults.semicolyn = .explicit(cfg)
                    }
                    .tint(Color(theme.accent.primary))
                }
            }
        } header: {
            Text("tmux")
        }
    }

    // MARK: - Privacy

    /// "Let server copy to clipboard" (OSC 52). The all-hosts "Don't learn from my
    /// typing" default lives in Settings > Suggestions & Privacy.
    private var privacySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Picker(selection: Binding(
                    get: { vm.defaults.semicolyn.value?.osc52?.allow },
                    set: { newAllow in
                        var cfg = vm.defaults.semicolyn.value ?? SemicolynConfig()
                        cfg.osc52 = newAllow.map { Osc52Config(allow: $0) }
                        vm.defaults.semicolyn = .explicit(cfg)
                    }
                )) {
                    Text(defaultChoiceLabel(onOffLabel(builtIn.osc52Allow))).tag(Bool?.none)
                    Text("On").tag(Bool?.some(true))
                    Text("Off").tag(Bool?.some(false))
                } label: {
                    Text(osc52Label)
                        .foregroundStyle(Color(theme.text.primary))
                }
                caption(osc52Caption)
            }
        } header: {
            Text("Privacy")
        }
    }

    // MARK: - Sign-in

    /// The SSH key a host with no key of its own uses (`Defaults.identities`).
    private var signInSection: some View {
        Section {
            Picker(selection: Binding(
                get: { defaultKeySelection(vm.defaults.identities) },
                set: { vm.defaults.identities = defaultKeyIdentities($0) }
            )) {
                Text("None").tag(IdentityRef?.none)
                ForEach(vm.identities, id: \.id) { identity in
                    Text(identity.displayName).tag(IdentityRef?.some(identity.id))
                }
            } label: {
                Text("Default SSH key")
                    .foregroundStyle(Color(theme.text.primary))
            }
        } header: {
            Text("Sign-in")
        } footer: {
            Text("Used by hosts that have no SSH key of their own.")
        }
    }
}

// MARK: - Shared wording (host editor and Connection Defaults)

/// "Use tmux" caption, shared by both editors.
let useTmuxCaption = "Opens (or creates) a tmux session when you connect, so your work survives disconnects. Swipe to switch windows; long-press the arrow pad for panes. Needs tmux on the server."

/// tmux session name caption, shared by both editors.
let tmuxSessionNameCaption = "Hosts with the same name share one session. Leave blank to use “semicolyn”."

/// The private-mode toggle label, shared by the host editor and Suggestions & Privacy.
let privateModeLabel = "Don't learn from my typing"

/// The OSC 52 row label and caption, shared by both editors.
let osc52Label = "Let server copy to clipboard"
let osc52Caption = "Programs on the server can write to your clipboard (OSC 52)."
