// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

/// The MVP entry screen: a connect form that, on success, swaps to the live
/// terminal. Host, port, user, and password are entered each launch (no
/// persistence yet — wiring the built `HostStore` is the next slice).
struct ConnectView: View {
    @StateObject private var vm = ConnectionViewModel()
    @State private var host = ""
    @State private var port = "22"
    @State private var user = ""
    @State private var password = ""

    var body: some View {
        if case .shell = vm.state, let session = vm.session {
            TerminalScreen(session: session, output: vm.output)
                .ignoresSafeArea(.container, edges: .bottom)
        } else {
            form
        }
    }

    private var form: some View {
        NavigationStack {
            Form {
                Section("Host") {
                    TextField("hostname", text: $host)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("port", text: $port)
                        .keyboardType(.numberPad)
                }
                Section("Authentication") {
                    TextField("user", text: $user)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    SecureField("password", text: $password)
                }
                Section {
                    Button {
                        vm.connect(host: host, port: port, user: user, password: password)
                    } label: {
                        if vm.state == .connecting {
                            ProgressView()
                        } else {
                            Text("Connect")
                        }
                    }
                    .disabled(host.isEmpty || user.isEmpty || vm.state == .connecting)
                }
                if case .failed(let message) = vm.state {
                    Section {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Glymr")
        }
        // The prompt sheet rides the connect form; `state` only becomes
        // `.shell` after `verify` has resolved, so the sheet is never orphaned.
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
    }
}
