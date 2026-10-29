// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import SemicolynKit

/// Confirm-before-connect sheet shown when the user taps an `ssh://` link in
/// terminal output. A tap never connects silently, the user sees the parsed
/// `user@host:port` and must hit **Connect** (Phase-3c ssh:// link seam).
struct QuickConnectSheet: View {
    let target: SSHConnectTarget
    let onConnect: () -> Void
    let onCancel: () -> Void

    /// `user@host:port`, omitting the parts the link didn't specify.
    private var address: String {
        let user = target.user.map { "\($0)@" } ?? ""
        let port = target.port.map { ":\($0)" } ?? ""
        return "\(user)\(target.host)\(port)"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "terminal")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                Text("Open SSH connection?")
                    .font(.headline)
                Text(address)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .multilineTextAlignment(.center)
                Spacer(minLength: 0)
            }
            .padding(.top, 28)
            .padding(.horizontal)
            .frame(maxWidth: .infinity)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { InputClickFeedback.play(); onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect") { InputClickFeedback.play(); onConnect() }.bold()
                }
            }
        }
        .presentationDetents([.height(240)])
    }
}

/// Hosts → "Connect to user@host…": type `[user@]host[:port]` (or an `ssh://` link)
/// and connect. The host is saved to the list on connect (the same find-or-create
/// as a tapped ssh:// link), so an existing match is reused instead of duplicated.
struct QuickConnectEntrySheet: View {
    let onConnect: (SSHConnectTarget) -> Void
    let onCancel: () -> Void
    @State private var address = ""
    @FocusState private var focused: Bool

    private var target: SSHConnectTarget? { parseQuickConnectAddress(address) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("user@host", text: $address)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .submitLabel(.go)
                        .focused($focused)
                        .onSubmit { if let target { InputClickFeedback.play(); onConnect(target) } }
                } footer: {
                    Text("For example alice@example.com or example.com:2222. It's saved to your hosts so you can connect again.")
                }
            }
            .navigationTitle("Connect to user@host")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { InputClickFeedback.play(); onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect") {
                        guard let target else { return }
                        InputClickFeedback.play()
                        onConnect(target)
                    }
                    .bold()
                    .disabled(target == nil)
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium])
    }
}
