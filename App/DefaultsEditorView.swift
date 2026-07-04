// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import SemicolynKit

/// Standalone Defaults editor — the singleton `Defaults` record.
///
/// Same section shell as `HostEditorView` but without `label`/`hostName`/Delete.
/// All sections are collapsed by default. Each row shows:
/// - `inherit · <fallback>` (in secondary color) when the field is `.inherit`
/// - The explicit value when the field is `.explicit`
///
/// Swipe-left on any `.explicit` row resets it to `.inherit` ("Clear override").
/// Save is always enabled — no required fields.
///
/// NOTE: This is a completely standalone view, NOT an extension of `HostEditorView`.
/// It reuses the pure mapper functions from `InheritedBinding.swift` (only).
struct DefaultsEditorView: View {
    @StateObject private var vm = DefaultsEditorViewModel()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    // Section expansion state — all collapsed by default (spec: §Defaults editor)
    @State private var basicsExpanded = false
    @State private var connectionExpanded = false
    @State private var jumpChainExpanded = false
    @State private var portForwardingExpanded = false
    @State private var moshExpanded = false
    @State private var tailscaleExpanded = false
    @State private var semicolynExpanded = false

    /// Whether to show the save-error alert (unexpected store failure).
    @State private var saveError: String? = nil

    var body: some View {
        NavigationStack {
            List {
                basicsSection
                connectionSection
                jumpChainSection
                portForwardingSection
                moshSection
                tailscaleSection
                semicolynSection
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .alert("Save failed", isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            )) {
                Button("OK", role: .cancel) { saveError = nil }
            } message: {
                Text(saveError ?? "")
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .principal) {
            Text("Defaults")
                .font(.headline)
                .foregroundStyle(Color(theme.text.primary))
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            Button("Save") { performSave() }
                .fontWeight(.semibold)
                .foregroundStyle(Color(theme.accent.primary))
        }
    }

    // MARK: - Basics section (user, port)

    private var basicsSection: some View {
        DisclosureGroup(isExpanded: $basicsExpanded) {

            // user — Inherited<String>; no built-in fallback → "(unset)"
            LabeledContent {
                TextField(
                    "inherit · (unset)",
                    text: Binding(
                        get: { inheritedStringToText(vm.defaults.user) },
                        set: { vm.defaults.user = textToInheritedString($0) }
                    )
                )
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .foregroundStyle(
                    vm.defaults.user == .inherit
                        ? Color(theme.text.secondary)
                        : Color(theme.text.primary)
                )
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

            // port — Inherited<Int>; built-in fallback: 22
            LabeledContent {
                TextField(
                    "inherit · 22",
                    text: Binding(
                        get: { inheritedIntToText(vm.defaults.port) },
                        set: { vm.defaults.port = textToInheritedInt($0) }
                    )
                )
                .keyboardType(.numberPad)
                .foregroundStyle(
                    vm.defaults.port == .inherit
                        ? Color(theme.text.secondary)
                        : Color(theme.text.primary)
                )
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

        } label: {
            Text("Basics")
                .font(.headline)
                .foregroundStyle(Color(theme.text.primary))
        }
    }

    // MARK: - Connection section

    private var connectionSection: some View {
        DisclosureGroup(isExpanded: $connectionExpanded) {

            // serverAliveInterval — Inherited<Int>; built-in fallback: 30
            LabeledContent {
                TextField(
                    "inherit · 30",
                    text: Binding(
                        get: { inheritedIntToText(vm.defaults.serverAliveInterval) },
                        set: { vm.defaults.serverAliveInterval = textToInheritedInt($0, minimum: 0) }
                    )
                )
                .keyboardType(.numberPad)
                .foregroundStyle(
                    vm.defaults.serverAliveInterval == .inherit
                        ? Color(theme.text.secondary)
                        : Color(theme.text.primary)
                )
            } label: {
                Text("Keep-alive interval (s)")
                    .foregroundStyle(Color(theme.text.primary))
            }
            .swipeActions {
                if case .explicit = vm.defaults.serverAliveInterval {
                    Button("Clear override") { vm.defaults.serverAliveInterval = .inherit }
                        .tint(Color(theme.accent.primary))
                }
            }

            // serverAliveCountMax — Inherited<Int>; built-in fallback: 3
            LabeledContent {
                TextField(
                    "inherit · 3",
                    text: Binding(
                        get: { inheritedIntToText(vm.defaults.serverAliveCountMax) },
                        set: { vm.defaults.serverAliveCountMax = textToInheritedInt($0, minimum: 0) }
                    )
                )
                .keyboardType(.numberPad)
                .foregroundStyle(
                    vm.defaults.serverAliveCountMax == .inherit
                        ? Color(theme.text.secondary)
                        : Color(theme.text.primary)
                )
            } label: {
                Text("Keep-alive retries")
                    .foregroundStyle(Color(theme.text.primary))
            }
            .swipeActions {
                if case .explicit = vm.defaults.serverAliveCountMax {
                    Button("Clear override") { vm.defaults.serverAliveCountMax = .inherit }
                        .tint(Color(theme.accent.primary))
                }
            }

            // compression — Inherited<Bool>: three-state Picker; built-in fallback: false
            // "inherit · false" label shown in-row; swipe row is the Picker row itself.
            compressionRow

            // forwardAgent — Inherited<Bool>: three-state Picker; built-in fallback: false
            forwardAgentRow

            // strictHostKeyChecking — Inherited<StrictHostKeyChecking>: Picker
            // built-in fallback: accept-new
            shkRow

            // preferredAuthentications — Inherited<[AuthMethod]>: per-method toggles
            preferredAuthSection

        } label: {
            Text("Connection")
                .font(.headline)
                .foregroundStyle(Color(theme.text.primary))
        }
    }

    // Compression row as a named var so swipeActions can be applied cleanly.
    private var compressionRow: some View {
        Picker(selection: Binding(
            get: { inheritedBoolToSelection(vm.defaults.compression) },
            set: { vm.defaults.compression = selectionToInheritedBool($0) }
        )) {
            Text("inherit · false").tag(Bool?.none)
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
            Text("inherit · false").tag(Bool?.none)
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
            Text("inherit · accept-new").tag(StrictHostKeyChecking?.none)
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

    /// Per-method toggles for `preferredAuthentications`.
    /// When `.inherit`, shows a muted "inherit · publickey, keyboard-interactive, password" hint.
    /// Toggling any method promotes the field to `.explicit`.
    private var preferredAuthSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Preferred auth")
                    .foregroundStyle(Color(theme.text.primary))
                Spacer()
                if case .explicit = vm.defaults.preferredAuthentications {
                    Button("Clear") { vm.defaults.preferredAuthentications = .inherit }
                        .font(.caption)
                        .foregroundStyle(Color(theme.accent.primary))
                }
            }

            if case .inherit = vm.defaults.preferredAuthentications {
                Text("inherit · publickey, keyboard-interactive, password")
                    .font(.caption)
                    .foregroundStyle(Color(theme.text.secondary))
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

    // MARK: - Jump chain section (deferred list editing)

    /// Jump chain section for Defaults.
    ///
    /// NOTE: List-typed field editing (proxyJump) is deferred for Defaults.
    /// Editing a default jump chain is a rare power-user case with no clear UX
    /// precedent in this app (the hop editor needs a host context for "Pick host"
    /// mode). A placeholder row is shown instead; per-host editing remains
    /// available via HostEditorView. See Task 7 report for rationale.
    private var jumpChainSection: some View {
        DisclosureGroup(isExpanded: $jumpChainExpanded) {
            Text("Set per-host — no global default")
                .font(.subheadline)
                .foregroundStyle(Color(theme.text.secondary))
                .italic()
        } label: {
            Text("Jump chain")
                .font(.headline)
                .foregroundStyle(Color(theme.text.primary))
        }
    }

    // MARK: - Port forwarding section (deferred list editing)

    /// Port forwarding section for Defaults.
    ///
    /// NOTE: List-typed field editing (localForwards, remoteForwards,
    /// dynamicForwards) is deferred for Defaults. Setting forwarding defaults
    /// globally is an advanced case; per-host editing remains available.
    /// See Task 7 report for rationale.
    private var portForwardingSection: some View {
        DisclosureGroup(isExpanded: $portForwardingExpanded) {
            Text("Set per-host — no global default")
                .font(.subheadline)
                .foregroundStyle(Color(theme.text.secondary))
                .italic()
        } label: {
            Text("Port forwarding")
                .font(.headline)
                .foregroundStyle(Color(theme.text.primary))
        }
    }

    // MARK: - Mosh section

    private var moshSection: some View {
        DisclosureGroup(isExpanded: $moshExpanded) {

            // mosh.enabled master toggle
            Toggle(isOn: Binding(
                get: { vm.defaults.mosh.value?.enabled ?? false },
                set: { newEnabled in
                    var cfg = vm.defaults.mosh.value ?? MoshConfig(enabled: false)
                    cfg.enabled = newEnabled
                    vm.defaults.mosh = .explicit(cfg)
                }
            )) {
                Text("Enable Mosh by default")
                    .foregroundStyle(Color(theme.text.primary))
            }
            .swipeActions {
                if case .explicit = vm.defaults.mosh {
                    Button("Clear override") { vm.defaults.mosh = .inherit }
                        .tint(Color(theme.accent.primary))
                }
            }

            // Leaf fields when mosh is explicitly enabled
            if vm.defaults.mosh.value?.enabled == true {

                LabeledContent {
                    TextField(
                        "e.g. /usr/local/bin/mosh-server",
                        text: Binding(
                            get: { vm.defaults.mosh.value?.serverPath ?? "" },
                            set: { newPath in
                                var cfg = vm.defaults.mosh.value ?? MoshConfig(enabled: true)
                                cfg.serverPath = newPath.isEmpty ? nil : newPath
                                vm.defaults.mosh = .explicit(cfg)
                            }
                        )
                    )
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                } label: {
                    Text("Server path")
                        .foregroundStyle(Color(theme.text.primary))
                }

                LabeledContent {
                    HStack(spacing: 8) {
                        TextField(
                            "lo",
                            text: Binding(
                                get: {
                                    if let range = vm.defaults.mosh.value?.udpPortRange,
                                       range.count >= 2 { return String(range[0]) }
                                    return ""
                                },
                                set: { newLo in
                                    var cfg = vm.defaults.mosh.value ?? MoshConfig(enabled: true)
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

                        Text("–")
                            .foregroundStyle(Color(theme.text.secondary))

                        TextField(
                            "hi",
                            text: Binding(
                                get: {
                                    if let range = vm.defaults.mosh.value?.udpPortRange,
                                       range.count >= 2 { return String(range[1]) }
                                    return ""
                                },
                                set: { newHi in
                                    var cfg = vm.defaults.mosh.value ?? MoshConfig(enabled: true)
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
                    Text("UDP port range")
                        .foregroundStyle(Color(theme.text.primary))
                }

                Picker(selection: Binding(
                    get: { vm.defaults.mosh.value?.predictionMode },
                    set: { newMode in
                        var cfg = vm.defaults.mosh.value ?? MoshConfig(enabled: true)
                        cfg.predictionMode = newMode
                        vm.defaults.mosh = .explicit(cfg)
                    }
                )) {
                    Text("Default").tag(MoshPredictionMode?.none)
                    Text("Adaptive").tag(MoshPredictionMode?.some(.adaptive))
                    Text("Always").tag(MoshPredictionMode?.some(.always))
                    Text("Never").tag(MoshPredictionMode?.some(.never))
                    Text("Experimental").tag(MoshPredictionMode?.some(.experimental))
                } label: {
                    Text("Prediction mode")
                        .foregroundStyle(Color(theme.text.primary))
                }
            }

            // When mosh is inherit (not explicitly configured), show hint
            if case .inherit = vm.defaults.mosh {
                Text("inherit · disabled")
                    .font(.caption)
                    .foregroundStyle(Color(theme.text.secondary))
            }

        } label: {
            Text("Mosh")
                .font(.headline)
                .foregroundStyle(Color(theme.text.primary))
        }
    }

    // MARK: - Tailscale section

    private var tailscaleSection: some View {
        DisclosureGroup(isExpanded: $tailscaleExpanded) {

            // tailscale.required toggle
            Toggle(isOn: Binding(
                get: { vm.defaults.tailscale.value?.required ?? false },
                set: { newRequired in
                    var cfg = vm.defaults.tailscale.value ?? TailscaleConfig(required: false)
                    cfg.required = newRequired
                    vm.defaults.tailscale = .explicit(cfg)
                }
            )) {
                Text("Tailscale required by default")
                    .foregroundStyle(Color(theme.text.primary))
            }
            .swipeActions {
                if case .explicit = vm.defaults.tailscale {
                    Button("Clear override") { vm.defaults.tailscale = .inherit }
                        .tint(Color(theme.accent.primary))
                }
            }

            // Tailnet — only visible when required is on
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

            if case .inherit = vm.defaults.tailscale {
                Text("inherit · not required")
                    .font(.caption)
                    .foregroundStyle(Color(theme.text.secondary))
            }

        } label: {
            Text("Tailscale")
                .font(.headline)
                .foregroundStyle(Color(theme.text.primary))
        }
    }

    // MARK: - Semicolyn behavior section

    private var semicolynSection: some View {
        DisclosureGroup(isExpanded: $semicolynExpanded) {

            // Predictor incognito — built-in fallback: false
            Toggle(isOn: Binding(
                get: { vm.defaults.semicolyn.value?.predictor?.incognito ?? false },
                set: { newIncognito in
                    var cfg = vm.defaults.semicolyn.value ?? SemicolynConfig()
                    var predictor = cfg.predictor ?? PredictorConfig()
                    predictor.incognito = newIncognito
                    cfg.predictor = predictor
                    vm.defaults.semicolyn = .explicit(cfg)
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Predictor incognito")
                        .foregroundStyle(Color(theme.text.primary))
                    Text("Don't learn from sessions by default.")
                        .font(.caption)
                        .foregroundStyle(Color(theme.text.secondary))
                }
            }
            .swipeActions {
                if case .explicit = vm.defaults.semicolyn {
                    Button("Clear override") { vm.defaults.semicolyn = .inherit }
                        .tint(Color(theme.accent.primary))
                }
            }

            // Tmux control mode — built-in fallback: true (attempt)
            Toggle(isOn: Binding(
                get: { vm.defaults.semicolyn.value?.tmux?.attemptControlMode ?? true },
                set: { newAttempt in
                    var cfg = vm.defaults.semicolyn.value ?? SemicolynConfig()
                    var tmux = cfg.tmux ?? TmuxConfig()
                    tmux.attemptControlMode = newAttempt
                    cfg.tmux = tmux
                    vm.defaults.semicolyn = .explicit(cfg)
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Attempt tmux control mode")
                        .foregroundStyle(Color(theme.text.primary))
                    Text("Automatically use tmux -CC if tmux is running (default on).")
                        .font(.caption)
                        .foregroundStyle(Color(theme.text.secondary))
                }
            }
            .swipeActions {
                if case .explicit = vm.defaults.semicolyn {
                    Button("Clear override") { vm.defaults.semicolyn = .inherit }
                        .tint(Color(theme.accent.primary))
                }
            }

            // Tmux session name — built-in fallback: inherit (semicolyn)
            LabeledContent {
                TextField(
                    "inherit · semicolyn",
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
            } label: {
                Text("tmux session name")
                    .foregroundStyle(Color(theme.text.primary))
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

            if case .inherit = vm.defaults.semicolyn {
                Text("inherit · predictor on, tmux control mode on")
                    .font(.caption)
                    .foregroundStyle(Color(theme.text.secondary))
            }

        } label: {
            Text("Semicolyn behavior")
                .font(.headline)
                .foregroundStyle(Color(theme.text.primary))
        }
    }

    // MARK: - Save action

    private func performSave() {
        do {
            try vm.save()
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}
