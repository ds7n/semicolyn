// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import SemicolynKit

/// Settings → Connections → Known Hosts (M-71): every trusted host key (host, key
/// type, SHA256 fingerprint, date added), built by Kit `knownHostRows`. Swipe
/// "Remove" deletes the key after a confirmation; the next connection to that host
/// then asks to trust it again (first-trust prompt).
struct KnownHostsView: View {
    @State private var rows: [KnownHostRow] = []
    @State private var pendingRemove: KnownHostRow?
    @State private var errorText: String?

    var body: some View {
        List {
            if rows.isEmpty {
                Section {
                    Text("No known hosts yet.")
                        .foregroundStyle(.secondary)
                } footer: {
                    Text("A host's key is saved here the first time you trust it.")
                }
            } else {
                Section {
                    ForEach(rows) { row in
                        KnownHostRowView(row: row)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                // Not `role: .destructive`, which animates the row away
                                // before the user has confirmed.
                                Button {
                                    InputClickFeedback.play()
                                    pendingRemove = row
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                                .tint(.red)
                            }
                    }
                } footer: {
                    Text("Swipe a key to remove it.")
                }
            }
        }
        .navigationTitle("Known Hosts")
        .confirmationDialog(
            "Remove the \(pendingRemove?.keyType ?? "") key for “\(pendingRemove?.hostLabel ?? "")”?",
            isPresented: Binding(get: { pendingRemove != nil },
                                 set: { if !$0 { pendingRemove = nil } }),
            titleVisibility: .visible,
            presenting: pendingRemove
        ) { row in
            Button("Remove", role: .destructive) {
                InputClickFeedback.play()
                remove(row)
                pendingRemove = nil
            }
            Button("Cancel", role: .cancel) { pendingRemove = nil }
        } message: { _ in
            Text(knownHostRemoveMessage)
        }
        .alert("Couldn't Remove Key", isPresented: Binding(
            get: { errorText != nil },
            set: { if !$0 { errorText = nil } }
        )) {
            Button("OK", role: .cancel) { errorText = nil }
        } message: {
            Text(errorText ?? "")
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        let hosts = (try? AppStores.shared.hosts.allHosts()) ?? []
        rows = knownHostRows(hosts: hosts, entries: AppStores.shared.hostKeys.entries(forHost:))
    }

    private func remove(_ row: KnownHostRow) {
        do {
            try AppStores.shared.hostKeys.remove(fingerprint: row.fingerprint, forHost: row.hostID)
            DebugLog.shared.log(.connect, "hostkey: removed (\(row.algorithm)) from Known Hosts")
        } catch {
            errorText = error.localizedDescription
        }
        reload()
    }
}

/// Host, key type, fingerprint and date added.
private struct KnownHostRowView: View {
    let row: KnownHostRow

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(row.hostLabel)
                Spacer()
                Text(row.keyType)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if row.hostName != row.hostLabel {
                Text(row.hostName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(row.displayFingerprint)
                .font(.caption.monospaced())
                .textSelection(.enabled)
            Text("Added \(row.addedAt.formatted(date: .abbreviated, time: .omitted))")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
