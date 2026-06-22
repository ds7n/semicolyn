// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import GlymrKit

/// Presents a live SSH session for a saved `Host`. Resolves credentials from
/// the host's stored `passwordRef` secret if available; otherwise prompts the
/// user to enter a password before connecting.
///
/// Auth scope (Phase 2a): password + keyboard-interactive only.
/// Publickey/cert connect is deferred to Phase 2b (Apple key-minting).
struct SessionView: View {
    let host: Host

    @StateObject private var vm = ConnectionViewModel()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    /// Password loaded from the Keychain-backed secret store, or entered by the
    /// user when no stored secret exists.
    @State private var password: String = ""
    /// True once we have looked up the stored secret (so we don't connect twice).
    @State private var credentialsResolved = false
    /// Set to true when the stored secret lookup failed to find a password,
    /// indicating the user must provide one manually.
    @State private var needsPasswordEntry = false

    var body: some View {
        Group {
            if case .shell = vm.state, let session = vm.session {
                TerminalScreen(session: session, output: vm.output)
                    .ignoresSafeArea(.container, edges: .bottom)
            } else if needsPasswordEntry && !credentialsResolved {
                passwordPrompt
            } else {
                statusView
            }
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
        .onAppear {
            resolveCredentials()
        }
    }

    // MARK: - Credential resolution

    /// Attempts to load the stored password from the Keychain secret store.
    /// If found, connects immediately. If not, shows the manual password prompt.
    private func resolveCredentials() {
        guard !credentialsResolved else { return }
        if let passwordID = host.passwordRef.value,
           let data = try? AppStores.shared.secrets.getSecret(.password(id: passwordID)) {
            let stored = String(decoding: data, as: UTF8.self)
            guard !stored.isEmpty else {
                needsPasswordEntry = true
                return
            }
            credentialsResolved = true
            password = stored
            vm.connect(savedHost: host, password: stored)
        } else {
            // No stored secret — surface the password entry form.
            needsPasswordEntry = true
        }
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
                    // Phase 2b note — publickey/cert connect deferred.
                    Text("Password or keyboard-interactive auth only (key auth coming in 2b).")
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
