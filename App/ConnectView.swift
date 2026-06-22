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
    }
}
