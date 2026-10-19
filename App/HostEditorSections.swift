// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import SemicolynKit

// MARK: - Connection section

extension HostEditorView {

    /// Effective transport for menu gating (tmux-toggle visibility, Mosh section visibility).
    /// Resolves against `vm.defaults` (`resolveTransport`) rather than reading the host's
    /// explicit leaf directly, so a legacy host with `mosh.enabled=true` but no explicit
    /// `transport` (which still resolves to `.mosh` at connect time via `resolveTransport`'s
    /// legacy migration) shows the Mosh section instead of silently hiding it.
    var selectedTransport: Transport {
        resolveTransport(host: vm.host, defaults: vm.defaults)
    }

    /// What "Default" would resolve to for this host (its transport left unset),
    /// shown as "Default (X)". Usually the Defaults value or SSH; an old Mosh host
    /// with an enabled Mosh config of its own still resolves to Mosh.
    var inheritedTransport: Transport {
        var unset = vm.host
        unset.transport = .inherit
        return resolveTransport(host: unset, defaults: vm.defaults)
    }

    /// Connection section: connection type, SSH keep-alive, and (hidden until wired,
    /// `UnwiredOptions`) the Tier-2 SSH options. All `Inherited<T>`, collapsed by default.
    var connectionSection: some View {
        DisclosureGroup(isExpanded: $connectionExpanded) {
            // transport, Inherited<Transport>: four-state Picker (Default (X) / SSH / Mosh / ET)
            Picker(selection: Binding(
                get: {
                    switch vm.host.transport {
                    case .inherit: return "default"
                    case .explicit(let t): return t?.rawValue ?? "default"
                    }
                },
                set: { (sel: String) in
                    vm.host.transport = (sel == "default") ? .inherit : .explicit(Transport(rawValue: sel))
                    vm.revalidate()
                }
            )) {
                Text(defaultChoiceLabel(inheritedTransport.displayName)).tag("default")
                ForEach(Transport.allCases, id: \.rawValue) { t in
                    Text(t.displayName).tag(t.rawValue)
                }
            } label: {
                Text("Connection type")
                    .foregroundStyle(Color(theme.text.primary))
            }

            // Summary of the type in effect, "Default (X)" included.
            Text(selectedTransport.summary + " Leave on SSH if unsure.")
                .font(.footnote)
                .foregroundStyle(Color(theme.text.secondary))

            // serverAliveInterval, Inherited<Int>. Used by the SSH connection, and by
            // Mosh / ET while they set up over SSH.
            LabeledContent {
                TextField(
                    defaultPlaceholder(String(fallbacks.keepAliveInterval)),
                    text: Binding(
                        get: { inheritedIntToText(vm.host.serverAliveInterval) },
                        set: { vm.host.serverAliveInterval = textToInheritedInt($0, minimum: 0) }
                    )
                )
                .keyboardType(.numberPad)
                .onChange(of: vm.host.serverAliveInterval) { _, _ in vm.revalidate() }
            } label: {
                Text("SSH keep-alive every (seconds)")
                    .foregroundStyle(Color(theme.text.primary))
            }

            // serverAliveCountMax, Inherited<Int>
            LabeledContent {
                TextField(
                    defaultPlaceholder(String(fallbacks.keepAliveRetries)),
                    text: Binding(
                        get: { inheritedIntToText(vm.host.serverAliveCountMax) },
                        set: { vm.host.serverAliveCountMax = textToInheritedInt($0, minimum: 0) }
                    )
                )
                .keyboardType(.numberPad)
                .onChange(of: vm.host.serverAliveCountMax) { _, _ in vm.revalidate() }
            } label: {
                Text("Missed replies before disconnect")
                    .foregroundStyle(Color(theme.text.primary))
            }

            Text(selectedTransport == .ssh
                 ? "Sends a small signal so idle connections don't drop."
                 : "Only used while setting up the connection.")
                .font(.caption)
                .foregroundStyle(Color(theme.text.secondary))

            if UnwiredOptions.compression {
                // compression, Inherited<Bool>: three-state Picker (Default / On / Off)
                Picker(selection: Binding(
                    get: { inheritedBoolToSelection(vm.host.compression) },
                    set: { vm.host.compression = selectionToInheritedBool($0); vm.revalidate() }
                )) {
                    Text(defaultChoiceLabel("Off")).tag(Bool?.none)
                    Text("On").tag(Bool?.some(true))
                    Text("Off").tag(Bool?.some(false))
                } label: {
                    Text("Compression")
                        .foregroundStyle(Color(theme.text.primary))
                }
            }

            if UnwiredOptions.agentForwarding {
                // forwardAgent, Inherited<Bool>: three-state Picker (Default / On / Off)
                Picker(selection: Binding(
                    get: { inheritedBoolToSelection(vm.host.forwardAgent) },
                    set: { vm.host.forwardAgent = selectionToInheritedBool($0); vm.revalidate() }
                )) {
                    Text(defaultChoiceLabel("Off")).tag(Bool?.none)
                    Text("On").tag(Bool?.some(true))
                    Text("Off").tag(Bool?.some(false))
                } label: {
                    Text("Agent forwarding")
                        .foregroundStyle(Color(theme.text.primary))
                }
            }

            if UnwiredOptions.hostKeyChecking {
                // strictHostKeyChecking, Inherited<StrictHostKeyChecking>: Picker
                Picker(selection: Binding(
                    get: { inheritedSHKCToSelection(vm.host.strictHostKeyChecking) },
                    set: { vm.host.strictHostKeyChecking = selectionToInheritedSHKC($0); vm.revalidate() }
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
            }

            if UnwiredOptions.preferredAuth {
                preferredAuthRows
            }

        } label: {
            Text("Connection")
                .font(.headline)
                .foregroundStyle(Color(theme.text.primary))
        }
    }

    /// preferredAuthentications, Inherited<[AuthMethod]>: toggles per method. Hidden
    /// until wired (`UnwiredOptions.preferredAuth`).
    private var preferredAuthRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Preferred auth")
                .foregroundStyle(Color(theme.text.primary))

            ForEach([AuthMethod.publicKey, .password, .keyboardInteractive], id: \.self) { method in
                let methodLabel: String = {
                    switch method {
                    case .publicKey: return "Public key"
                    case .password: return "Password"
                    case .keyboardInteractive: return "Keyboard-interactive"
                    }
                }()
                let isActive: Bool = vm.host.preferredAuthentications.value?.contains(method) ?? false

                Toggle(isOn: Binding(
                    get: { isActive },
                    set: { newValue in
                        // Promote to explicit on first toggle, then toggle the method
                        var current: Set<AuthMethod> = inheritedAuthMethodsToSelection(
                            vm.host.preferredAuthentications
                        ) ?? Set()
                        if newValue {
                            current.insert(method)
                        } else {
                            current.remove(method)
                        }
                        vm.host.preferredAuthentications = selectionToInheritedAuthMethods(current)
                        vm.revalidate()
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
}

// MARK: - Jump chain section

extension HostEditorView {

    /// Jump chain section: `proxyJump[]` list with per-hop mode toggle.
    var jumpChainSection: some View {
        DisclosureGroup(isExpanded: $jumpChainExpanded) {
            // Cycle banner, section-level hard issue
            if hasIssue(.jumpChainCycle) {
                IssueBanner(
                    message: "Jump chain contains a cycle.",
                    severity: .hardBlock
                )
            }

            let hops: [JumpHop] = vm.host.proxyJump.value ?? []

            ForEach(hops.indices, id: \.self) { idx in
                JumpHopRow(
                    hop: Binding(
                        get: { hops[idx] },
                        set: { newHop in
                            var updated = vm.host.proxyJump.value ?? []
                            updated[idx] = newHop
                            vm.host.proxyJump = .explicit(updated)
                            vm.revalidate()
                        }
                    ),
                    index: idx,
                    editingHostId: vm.host.id,
                    issues: vm.issues,
                    onRemove: {
                        var updated = vm.host.proxyJump.value ?? []
                        updated.remove(at: idx)
                        vm.host.proxyJump = .explicit(updated)
                        vm.revalidate()
                    }
                )
            }

            Button {
                InputClickFeedback.play()
                var updated = vm.host.proxyJump.value ?? []
                updated.append(.inline(hostName: "", port: nil, user: nil, identities: nil))
                vm.host.proxyJump = .explicit(updated)
                vm.revalidate()
            } label: {
                Label("Add hop", systemImage: "plus.circle")
                    .foregroundStyle(Color(theme.accent.primary))
            }

        } label: {
            Text("Jump chain")
                .font(.headline)
                .foregroundStyle(Color(theme.text.primary))
        }
    }
}

// MARK: - Port forwarding section

extension HostEditorView {

    /// Port forwarding section: three sub-lists (local / remote / dynamic).
    var portForwardingSection: some View {
        DisclosureGroup(isExpanded: $portForwardingExpanded) {

            // ── Local forwards ──────────────────────────────────────────────
            Text("Local forwards")
                .font(.subheadline)
                .foregroundStyle(Color(theme.text.secondary))

            let localFwds: [LocalForward] = vm.host.localForwards.value ?? []
            ForEach(localFwds.indices, id: \.self) { idx in
                LocalForwardRow(
                    fwd: Binding(
                        get: { localFwds[idx] },
                        set: { newFwd in
                            var updated = vm.host.localForwards.value ?? []
                            updated[idx] = newFwd
                            vm.host.localForwards = .explicit(updated)
                            vm.revalidate()
                        }
                    ),
                    index: idx,
                    issues: vm.issues,
                    onRemove: {
                        var updated = vm.host.localForwards.value ?? []
                        updated.remove(at: idx)
                        vm.host.localForwards = .explicit(updated)
                        vm.revalidate()
                    }
                )
            }
            Button {
                InputClickFeedback.play()
                var updated = vm.host.localForwards.value ?? []
                updated.append(LocalForward(bindAddress: nil, bindPort: 0, hostAddress: "", hostPort: 0))
                vm.host.localForwards = .explicit(updated)
                vm.revalidate()
            } label: {
                Label("Add local forward", systemImage: "plus.circle")
                    .foregroundStyle(Color(theme.accent.primary))
            }

            // ── Remote forwards ─────────────────────────────────────────────
            Text("Remote forwards")
                .font(.subheadline)
                .foregroundStyle(Color(theme.text.secondary))
                .padding(.top, 4)

            let remoteFwds: [RemoteForward] = vm.host.remoteForwards.value ?? []
            ForEach(remoteFwds.indices, id: \.self) { idx in
                RemoteForwardRow(
                    fwd: Binding(
                        get: { remoteFwds[idx] },
                        set: { newFwd in
                            var updated = vm.host.remoteForwards.value ?? []
                            updated[idx] = newFwd
                            vm.host.remoteForwards = .explicit(updated)
                            vm.revalidate()
                        }
                    ),
                    index: idx,
                    issues: vm.issues,
                    onRemove: {
                        var updated = vm.host.remoteForwards.value ?? []
                        updated.remove(at: idx)
                        vm.host.remoteForwards = .explicit(updated)
                        vm.revalidate()
                    }
                )
            }
            Button {
                InputClickFeedback.play()
                var updated = vm.host.remoteForwards.value ?? []
                updated.append(RemoteForward(bindAddress: nil, bindPort: 0, hostAddress: "", hostPort: 0))
                vm.host.remoteForwards = .explicit(updated)
                vm.revalidate()
            } label: {
                Label("Add remote forward", systemImage: "plus.circle")
                    .foregroundStyle(Color(theme.accent.primary))
            }

            // ── Dynamic forwards ────────────────────────────────────────────
            Text("Dynamic forwards (SOCKS)")
                .font(.subheadline)
                .foregroundStyle(Color(theme.text.secondary))
                .padding(.top, 4)

            let dynFwds: [DynamicForward] = vm.host.dynamicForwards.value ?? []
            ForEach(dynFwds.indices, id: \.self) { idx in
                DynamicForwardRow(
                    fwd: Binding(
                        get: { dynFwds[idx] },
                        set: { newFwd in
                            var updated = vm.host.dynamicForwards.value ?? []
                            updated[idx] = newFwd
                            vm.host.dynamicForwards = .explicit(updated)
                            vm.revalidate()
                        }
                    ),
                    index: idx,
                    issues: vm.issues,
                    onRemove: {
                        var updated = vm.host.dynamicForwards.value ?? []
                        updated.remove(at: idx)
                        vm.host.dynamicForwards = .explicit(updated)
                        vm.revalidate()
                    }
                )
            }
            Button {
                InputClickFeedback.play()
                var updated = vm.host.dynamicForwards.value ?? []
                updated.append(DynamicForward(bindAddress: nil, bindPort: 0))
                vm.host.dynamicForwards = .explicit(updated)
                vm.revalidate()
            } label: {
                Label("Add dynamic forward", systemImage: "plus.circle")
                    .foregroundStyle(Color(theme.accent.primary))
            }

        } label: {
            Text("Port forwarding")
                .font(.headline)
                .foregroundStyle(Color(theme.text.primary))
        }
    }
}

// MARK: - Mosh section

extension HostEditorView {

    /// Mosh section: server path, UDP ports, local echo.
    /// Only composed (in `HostEditorView.body`) when the selected transport is Mosh;
    /// selecting Transport=Mosh in the Connection section's picker is the enable signal,
    /// so there is no separate master toggle here.
    /// Collapsed by default; auto-expands on edit when `mosh` is explicitly configured.
    var moshSection: some View {
        DisclosureGroup(isExpanded: $moshExpanded) {

            // Server path, optional text
            LabeledContent {
                TextField(
                    "e.g. /usr/local/bin/mosh-server",
                    text: Binding(
                        get: { vm.host.mosh.value?.serverPath ?? "" },
                        set: { newPath in
                            var cfg = vm.host.mosh.value ?? MoshConfig(enabled: false)
                            cfg.serverPath = newPath.isEmpty ? nil : newPath
                            vm.host.mosh = .explicit(cfg)
                            vm.revalidate()
                        }
                    )
                )
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            } label: {
                Text("Server path")
                    .foregroundStyle(Color(theme.text.primary))
            }
            Text("Only needed if mosh-server isn't found automatically.")
                .font(.caption)
                .foregroundStyle(Color(theme.text.secondary))

            // UDP port range, lo / hi pair
            LabeledContent {
                HStack(spacing: 8) {
                    TextField(
                        "From",
                        text: Binding(
                            get: {
                                if let range = vm.host.mosh.value?.udpPortRange, range.count >= 2 {
                                    return String(range[0])
                                }
                                return ""
                            },
                            set: { newLo in
                                var cfg = vm.host.mosh.value ?? MoshConfig(enabled: false)
                                let lo = Int(newLo) ?? 0
                                let existingRange = cfg.udpPortRange
                                let hi = (existingRange != nil && existingRange!.count >= 2) ? existingRange![1] : 0
                                cfg.udpPortRange = (lo > 0 || hi > 0) ? [lo, hi] : nil
                                vm.host.mosh = .explicit(cfg)
                                vm.revalidate()
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
                                if let range = vm.host.mosh.value?.udpPortRange, range.count >= 2 {
                                    return String(range[1])
                                }
                                return ""
                            },
                            set: { newHi in
                                var cfg = vm.host.mosh.value ?? MoshConfig(enabled: false)
                                let existingRange = cfg.udpPortRange
                                let lo = (existingRange != nil && existingRange!.count >= 2) ? existingRange![0] : 0
                                let hi = Int(newHi) ?? 0
                                cfg.udpPortRange = (lo > 0 || hi > 0) ? [lo, hi] : nil
                                vm.host.mosh = .explicit(cfg)
                                vm.revalidate()
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
            Text("Leave blank unless your firewall needs a fixed range, for example 60000 to 61000.")
                .font(.caption)
                .foregroundStyle(Color(theme.text.secondary))

            // Local echo (mosh prediction mode). "Default" already sends adaptive, so
            // unset and .adaptive share the "Adaptive (default)" row.
            Picker(selection: Binding(
                get: { moshLocalEchoSelection(vm.host.mosh.value?.predictionMode) },
                set: { newMode in
                    var cfg = vm.host.mosh.value ?? MoshConfig(enabled: false)
                    cfg.predictionMode = newMode
                    vm.host.mosh = .explicit(cfg)
                    vm.revalidate()
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
            Text("Shows your typing before the server confirms it. Adaptive does this only on slow connections.")
                .font(.caption)
                .foregroundStyle(Color(theme.text.secondary))

        } label: {
            Text("Mosh")
                .font(.headline)
                .foregroundStyle(Color(theme.text.primary))
        }
    }
}

// MARK: - Tailscale section

extension HostEditorView {

    /// Tailscale section: required toggle; tailnet text field when required.
    /// Collapsed by default; auto-expands on edit when `tailscale` is explicitly configured.
    var tailscaleSection: some View {
        DisclosureGroup(isExpanded: $tailscaleExpanded) {

            // Caveat banner when tailscale.required is on
            if vm.host.tailscale.value?.required == true {
                IssueBanner(
                    message: "Connection refused with a 'Tailscale required' banner when Tailscale is disconnected.",
                    severity: .softBlock
                )
            }

            // Required toggle
            Toggle(isOn: Binding(
                get: { vm.host.tailscale.value?.required ?? false },
                set: { newRequired in
                    var cfg = vm.host.tailscale.value ?? TailscaleConfig(required: false)
                    cfg.required = newRequired
                    vm.host.tailscale = .explicit(cfg)
                    vm.revalidate()
                }
            )) {
                Text("Tailscale required")
                    .foregroundStyle(Color(theme.text.primary))
            }
            .onChange(of: vm.host.tailscale) { _, _ in vm.revalidate() }

            // Tailnet, only visible when required is on
            if vm.host.tailscale.value?.required == true {
                LabeledContent {
                    TextField(
                        "e.g. mycompany.ts.net",
                        text: Binding(
                            get: { vm.host.tailscale.value?.tailnet ?? "" },
                            set: { newTailnet in
                                var cfg = vm.host.tailscale.value ?? TailscaleConfig(required: true)
                                cfg.tailnet = newTailnet.isEmpty ? nil : newTailnet
                                vm.host.tailscale = .explicit(cfg)
                                vm.revalidate()
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

        } label: {
            Text("Tailscale")
                .font(.headline)
                .foregroundStyle(Color(theme.text.primary))
        }
    }
}

// MARK: - tmux and Privacy sections

extension HostEditorView {

    /// tmux section: Use tmux and the session name. Collapsed by default; expands on
    /// edit when the host sets either.
    var tmuxSection: some View {
        DisclosureGroup(isExpanded: $tmuxExpanded) {
            // Use tmux, default true per resolution. Shown for all transports:
            // native gestures (swipe, long-press, tap) drive plain tmux over
            // SSH/Mosh/ET alike.
            Toggle(isOn: Binding(
                get: { vm.host.semicolyn.value?.tmux?.useTmux ?? true },
                set: { newUseTmux in
                    var cfg = vm.host.semicolyn.value ?? SemicolynConfig()
                    var tmux = cfg.tmux ?? TmuxConfig()
                    tmux.useTmux = newUseTmux
                    cfg.tmux = tmux
                    vm.host.semicolyn = .explicit(cfg)
                    vm.revalidate()
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Use tmux")
                        .foregroundStyle(Color(theme.text.primary))
                    Text(useTmuxCaption)
                        .font(.caption)
                        .foregroundStyle(Color(theme.text.secondary))
                }
            }

            // tmux session name, Inherited via the nested leaf. Blank = inherit
            // (→ Defaults → "semicolyn"). Disabled when tmux is off.
            let useTmuxOn = (vm.host.semicolyn.value?.tmux?.useTmux ?? true)
            LabeledContent {
                TextField(
                    defaultPlaceholder(fallbacks.tmuxSessionName),
                    text: Binding(
                        get: { vm.host.semicolyn.value?.tmux?.sessionName ?? "" },
                        set: { newName in
                            var cfg = vm.host.semicolyn.value ?? SemicolynConfig()
                            var tmux = cfg.tmux ?? TmuxConfig()
                            tmux.sessionName = newName.isEmpty ? nil : newName
                            cfg.tmux = tmux
                            vm.host.semicolyn = .explicit(cfg)
                        }
                    )
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onChange(of: vm.host.semicolyn) { _, _ in vm.revalidate() }
            } label: {
                Text("Session name")
                    .foregroundStyle(Color(theme.text.primary))
            }
            .disabled(!useTmuxOn)
            Text(tmuxSessionNameCaption)
                .font(.caption)
                .foregroundStyle(Color(theme.text.secondary))

            if vm.issues.contains(where: { $0.kind == .invalidTmuxSessionName }) {
                Text("Only letters, digits, - and _ (no spaces, dots, or colons).")
                    .font(.caption)
                    .foregroundStyle(Color(theme.state.broken))
            }
        } label: {
            Text("tmux")
                .font(.headline)
                .foregroundStyle(Color(theme.text.primary))
        }
    }

    /// Privacy section: private mode and OSC 52, both inheritable ("Default (X)" is
    /// the Connection Defaults value, else the built-in). Collapsed by default;
    /// expands on edit when the host sets either.
    var privacySection: some View {
        DisclosureGroup(isExpanded: $privacyExpanded) {
            // Private mode ("incognito" in the model), built-in default off
            VStack(alignment: .leading, spacing: 2) {
                Picker(selection: Binding(
                    get: { vm.host.semicolyn.value?.predictor?.incognito },
                    set: { newIncognito in
                        var cfg = vm.host.semicolyn.value ?? SemicolynConfig()
                        cfg.predictor = newIncognito.map { PredictorConfig(incognito: $0) }
                        vm.host.semicolyn = .explicit(cfg)
                        vm.revalidate()
                    }
                )) {
                    Text(defaultChoiceLabel(onOffLabel(fallbacks.privateMode))).tag(Bool?.none)
                    Text("On").tag(Bool?.some(true))
                    Text("Off").tag(Bool?.some(false))
                } label: {
                    Text(privateModeLabel)
                        .foregroundStyle(Color(theme.text.primary))
                }
                Text("Word suggestions still appear, but nothing you type or see on this host is learned.")
                    .font(.caption)
                    .foregroundStyle(Color(theme.text.secondary))
            }

            // OSC 52 clipboard, built-in default on
            VStack(alignment: .leading, spacing: 2) {
                Picker(selection: Binding(
                    get: { vm.host.semicolyn.value?.osc52?.allow },
                    set: { newAllow in
                        var cfg = vm.host.semicolyn.value ?? SemicolynConfig()
                        cfg.osc52 = newAllow.map { Osc52Config(allow: $0) }
                        vm.host.semicolyn = .explicit(cfg)
                        vm.revalidate()
                    }
                )) {
                    Text(defaultChoiceLabel(onOffLabel(fallbacks.osc52Allow))).tag(Bool?.none)
                    Text("On").tag(Bool?.some(true))
                    Text("Off").tag(Bool?.some(false))
                } label: {
                    Text(osc52Label)
                        .foregroundStyle(Color(theme.text.primary))
                }
                Text(osc52Caption)
                    .font(.caption)
                    .foregroundStyle(Color(theme.text.secondary))
            }
        } label: {
            Text("Privacy")
                .font(.headline)
                .foregroundStyle(Color(theme.text.primary))
        }
    }
}

// MARK: - Delete section

extension HostEditorView {

    /// Delete host row, edit mode only. Destructive styling; tapping opens the
    /// confirmation sheet managed in `HostEditorView.body`.
    var deleteSection: some View {
        Section {
            Button(role: .destructive) {
                InputClickFeedback.play()
                showingDeleteConfirm = true
            } label: {
                HStack {
                    Spacer()
                    Text("Delete Host")
                        .foregroundStyle(Color(theme.state.broken))
                    Spacer()
                }
            }
        }
    }
}

// MARK: - JumpHopRow

/// A single row in the jump chain list. Toggles between `.ref(hostId:)` and
/// `.inline(hostName:port:user:identities:)` modes.
private struct JumpHopRow: View {
    @Binding var hop: JumpHop
    let index: Int
    let editingHostId: UUID
    let issues: [ValidationIssue]
    let onRemove: () -> Void
    @Environment(\.theme) private var theme

    /// True when this row's inline hop has a missing hostName.
    private var hasInlineHostNameIssue: Bool {
        issues.contains { $0.kind == .inlineJumpHostMissingHostName(index: index) }
    }

    /// Whether the current hop is in "Pick host" mode.
    private var isRefMode: Bool {
        if case .ref = hop { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                // Mode toggle: Pick host vs Inline
                Picker("", selection: Binding<Bool>(
                    get: { isRefMode },
                    set: { wantsRef in
                        if wantsRef {
                            // Pre-select the first eligible (non-self) saved host so the
                            // Picker is never pointing at an arbitrary/invalid UUID.
                            let allHosts = (try? AppStores.shared.hosts.allHosts()) ?? []
                            let firstEligible = allHosts.first { $0.id != editingHostId }
                            hop = .ref(hostId: firstEligible?.id ?? UUID())
                        } else {
                            hop = .inline(hostName: "", port: nil, user: nil, identities: nil)
                        }
                    }
                )) {
                    Text("Pick host").tag(true)
                    Text("Inline").tag(false)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: .infinity)

                Button(role: .destructive) { InputClickFeedback.play(); onRemove() } label: {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(Color(theme.state.broken))
                }
                .buttonStyle(.borderless)
            }

            if isRefMode {
                refModeContent
            } else {
                inlineModeContent
            }

            if hasInlineHostNameIssue {
                IssueBanner(
                    message: "Inline jump host requires a hostname.",
                    severity: .hardBlock
                )
            }
        }
        .padding(.vertical, 2)
    }

    /// Picker over all saved hosts except the one being edited.
    @ViewBuilder
    private var refModeContent: some View {
        // TODO(perf): allHosts() is re-fetched on every render; cache in the view model and observe store changes.
        let savedHosts: [SemicolynKit.Host] = (try? AppStores.shared.hosts.allHosts())
            ?? []
        let eligible = savedHosts.filter { $0.id != editingHostId }

        if eligible.isEmpty {
            Text("No other saved hosts")
                .font(.caption)
                .foregroundStyle(Color(theme.text.secondary))
        } else {
            let currentId: UUID = {
                if case let .ref(id) = hop { return id }
                return eligible[0].id
            }()
            Picker("Host", selection: Binding<UUID>(
                get: { currentId },
                set: { hop = .ref(hostId: $0) }
            )) {
                ForEach(eligible, id: \.id) { h in
                    Text(h.label.isEmpty ? h.hostName : h.label).tag(h.id)
                }
            }
        }
    }

    /// Text fields for `user@host:port`.
    @ViewBuilder
    private var inlineModeContent: some View {
        let inlineHostName: String = {
            if case let .inline(hn, _, _, _) = hop { return hn }
            return ""
        }()
        let inlinePort: Int? = {
            if case let .inline(_, p, _, _) = hop { return p }
            return nil
        }()
        let inlineUser: String = {
            if case let .inline(_, _, u, _) = hop { return u ?? "" }
            return ""
        }()

        LabeledContent {
            TextField("hostname or IP", text: Binding(
                get: { inlineHostName },
                set: { newHN in
                    let (_, p, u, ids) = inlineFields
                    hop = .inline(hostName: newHN, port: p, user: u.isEmpty ? nil : u, identities: ids)
                }
            ))
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
        } label: {
            Text("Host")
                .font(.subheadline)
                .foregroundStyle(Color(theme.text.primary))
        }

        LabeledContent {
            TextField("e.g. 22", text: Binding(
                get: { inlinePort.map { String($0) } ?? "" },
                set: { newText in
                    let (hn, _, u, ids) = inlineFields
                    let port = Int(newText).flatMap { $0 > 0 ? $0 : nil }
                    hop = .inline(hostName: hn, port: port, user: u.isEmpty ? nil : u, identities: ids)
                }
            ))
            .keyboardType(.numberPad)
        } label: {
            Text("Port")
                .font(.subheadline)
                .foregroundStyle(Color(theme.text.primary))
        }

        LabeledContent {
            TextField("e.g. ubuntu", text: Binding(
                get: { inlineUser },
                set: { newUser in
                    let (hn, p, _, ids) = inlineFields
                    hop = .inline(hostName: hn, port: p, user: newUser.isEmpty ? nil : newUser, identities: ids)
                }
            ))
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
        } label: {
            Text("User")
                .font(.subheadline)
                .foregroundStyle(Color(theme.text.primary))
        }
    }

    /// Destructure the current hop's inline fields (safe; returns empty defaults otherwise).
    private var inlineFields: (String, Int?, String, [IdentityRef]?) {
        if case let .inline(hn, p, u, ids) = hop {
            return (hn, p, u ?? "", ids)
        }
        return ("", nil, "", nil)
    }
}

// MARK: - LocalForwardRow

private struct LocalForwardRow: View {
    @Binding var fwd: LocalForward
    let index: Int
    let issues: [ValidationIssue]
    let onRemove: () -> Void
    @Environment(\.theme) private var theme

    private var hasMissingField: Bool {
        issues.contains { $0.kind == .localForwardMissingField(index: index) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Local \(index + 1)")
                    .font(.subheadline)
                    .foregroundStyle(Color(theme.text.secondary))
                Spacer()
                Button(role: .destructive) { InputClickFeedback.play(); onRemove() } label: {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(Color(theme.state.broken))
                }
                .buttonStyle(.borderless)
            }

            LabeledContent {
                TextField("optional", text: Binding(
                    get: { fwd.bindAddress ?? "" },
                    set: { fwd.bindAddress = $0.isEmpty ? nil : $0 }
                ))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            } label: {
                Text("Bind addr")
                    .font(.caption)
                    .foregroundStyle(Color(theme.text.primary))
            }

            LabeledContent {
                TextField("bind port", text: Binding(
                    get: { fwd.bindPort > 0 ? String(fwd.bindPort) : "" },
                    set: { fwd.bindPort = Int($0) ?? 0 }
                ))
                .keyboardType(.numberPad)
            } label: {
                Text("Bind port")
                    .font(.caption)
                    .foregroundStyle(Color(theme.text.primary))
            }

            LabeledContent {
                TextField("hostname or IP", text: Binding(
                    get: { fwd.hostAddress },
                    set: { fwd.hostAddress = $0 }
                ))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
            } label: {
                Text("Host addr")
                    .font(.caption)
                    .foregroundStyle(Color(theme.text.primary))
            }

            LabeledContent {
                TextField("host port", text: Binding(
                    get: { fwd.hostPort > 0 ? String(fwd.hostPort) : "" },
                    set: { fwd.hostPort = Int($0) ?? 0 }
                ))
                .keyboardType(.numberPad)
            } label: {
                Text("Host port")
                    .font(.caption)
                    .foregroundStyle(Color(theme.text.primary))
            }

            if hasMissingField {
                IssueBanner(
                    message: "Bind port, host address, and host port are required.",
                    severity: .hardBlock
                )
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - RemoteForwardRow

private struct RemoteForwardRow: View {
    @Binding var fwd: RemoteForward
    let index: Int
    let issues: [ValidationIssue]
    let onRemove: () -> Void
    @Environment(\.theme) private var theme

    private var hasMissingField: Bool {
        issues.contains { $0.kind == .remoteForwardMissingField(index: index) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Remote \(index + 1)")
                    .font(.subheadline)
                    .foregroundStyle(Color(theme.text.secondary))
                Spacer()
                Button(role: .destructive) { InputClickFeedback.play(); onRemove() } label: {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(Color(theme.state.broken))
                }
                .buttonStyle(.borderless)
            }

            LabeledContent {
                TextField("optional", text: Binding(
                    get: { fwd.bindAddress ?? "" },
                    set: { fwd.bindAddress = $0.isEmpty ? nil : $0 }
                ))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            } label: {
                Text("Bind addr")
                    .font(.caption)
                    .foregroundStyle(Color(theme.text.primary))
            }

            LabeledContent {
                TextField("bind port", text: Binding(
                    get: { fwd.bindPort > 0 ? String(fwd.bindPort) : "" },
                    set: { fwd.bindPort = Int($0) ?? 0 }
                ))
                .keyboardType(.numberPad)
            } label: {
                Text("Bind port")
                    .font(.caption)
                    .foregroundStyle(Color(theme.text.primary))
            }

            LabeledContent {
                TextField("hostname or IP", text: Binding(
                    get: { fwd.hostAddress },
                    set: { fwd.hostAddress = $0 }
                ))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
            } label: {
                Text("Host addr")
                    .font(.caption)
                    .foregroundStyle(Color(theme.text.primary))
            }

            LabeledContent {
                TextField("host port", text: Binding(
                    get: { fwd.hostPort > 0 ? String(fwd.hostPort) : "" },
                    set: { fwd.hostPort = Int($0) ?? 0 }
                ))
                .keyboardType(.numberPad)
            } label: {
                Text("Host port")
                    .font(.caption)
                    .foregroundStyle(Color(theme.text.primary))
            }

            if hasMissingField {
                IssueBanner(
                    message: "Bind port, host address, and host port are required.",
                    severity: .hardBlock
                )
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - DynamicForwardRow

private struct DynamicForwardRow: View {
    @Binding var fwd: DynamicForward
    let index: Int
    let issues: [ValidationIssue]
    let onRemove: () -> Void
    @Environment(\.theme) private var theme

    private var hasMissingField: Bool {
        issues.contains { $0.kind == .dynamicForwardMissingField(index: index) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Dynamic \(index + 1)")
                    .font(.subheadline)
                    .foregroundStyle(Color(theme.text.secondary))
                Spacer()
                Button(role: .destructive) { InputClickFeedback.play(); onRemove() } label: {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(Color(theme.state.broken))
                }
                .buttonStyle(.borderless)
            }

            LabeledContent {
                TextField("optional", text: Binding(
                    get: { fwd.bindAddress ?? "" },
                    set: { fwd.bindAddress = $0.isEmpty ? nil : $0 }
                ))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            } label: {
                Text("Bind addr")
                    .font(.caption)
                    .foregroundStyle(Color(theme.text.primary))
            }

            LabeledContent {
                TextField("bind port", text: Binding(
                    get: { fwd.bindPort > 0 ? String(fwd.bindPort) : "" },
                    set: { fwd.bindPort = Int($0) ?? 0 }
                ))
                .keyboardType(.numberPad)
            } label: {
                Text("Bind port")
                    .font(.caption)
                    .foregroundStyle(Color(theme.text.primary))
            }

            if hasMissingField {
                IssueBanner(
                    message: "Bind port is required.",
                    severity: .hardBlock
                )
            }
        }
        .padding(.vertical, 2)
    }
}

// `IssueBanner` is declared internal (not private) in HostEditorView.swift and is
// visible to this file. No duplicate declaration needed.
