// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import UIKit
import SemicolynKit

/// Settings → Connections → SSH Keys (M-70): the saved keys, each with "Copy Public
/// Key", "Share Public Key", "Rename" and "Delete". Only the public key is ever shown,
/// copied or shared (`publicKeyShareText`); the private key stays in the Keychain.
/// Delete confirms with the hosts that use the key, then removes it from them too
/// (`IdentityService.deleteIdentity`), so no host points at a missing key.
struct SSHKeysView: View {
    @StateObject private var model = SSHKeysModel()
    @State private var adding = false

    var body: some View {
        List {
            if model.identities.isEmpty {
                Section {
                    Text("No saved keys yet.")
                        .foregroundStyle(.secondary)
                } footer: {
                    Text("Tap + to create or import a key.")
                }
            } else {
                Section {
                    ForEach(model.identities, id: \.id) { identity in
                        NavigationLink {
                            SSHKeyDetailView(identityID: identity.id)
                        } label: {
                            SSHKeyRow(identity: identity)
                        }
                        .contextMenu { SSHKeyActions(model: model, identity: identity) }
                    }
                } footer: {
                    Text("Private keys stay in your Keychain and are never shown or shared.")
                }
            }
        }
        .navigationTitle("SSH Keys")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { InputClickFeedback.play(); adding = true } label: {
                    Label("Add Key", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $adding, onDismiss: model.reload) {
            IdentityPickerSheet(showsSavedTab: false) { _ in }
        }
        .sshKeyDialogs(model)
        .onAppear(perform: model.reload)
    }
}

/// The saved keys plus the rename and delete flows. The list and the detail screen
/// each own one, so each presents its own dialogs.
@MainActor
final class SSHKeysModel: ObservableObject {
    @Published private(set) var identities: [Identity] = []
    /// The key being renamed (drives the Rename alert) and the edited name.
    @Published var renaming: Identity?
    @Published var renameText = ""
    /// The key awaiting delete confirmation and where it is used.
    @Published var pendingDelete: Identity?
    @Published private(set) var pendingUsage = IdentityUsage(hosts: [], isDefaultKey: false)
    @Published var errorText: String?

    /// Re-read the keys, sorted by name.
    func reload() {
        identities = ((try? AppStores.shared.hosts.allIdentities()) ?? [])
            .sorted { $0.displayName.lowercased() < $1.displayName.lowercased() }
    }

    func identity(id: UUID) -> Identity? { identities.first { $0.id == id } }

    func beginRename(_ identity: Identity) {
        renameText = identity.displayName
        renaming = identity
    }

    func commitRename() {
        guard let identity = renaming else { return }
        renaming = nil
        do {
            try AppStores.shared.identities.rename(identityID: identity.id, to: renameText)
        } catch IdentityEditError.emptyName {
            errorText = "A key needs a name."
        } catch {
            errorText = "Couldn't rename the key: \(error.localizedDescription)"
        }
        reload()
    }

    func beginDelete(_ identity: Identity) {
        pendingUsage = (try? AppStores.shared.hosts.identityUsage(identityID: identity.id))
            ?? IdentityUsage(hosts: [], isDefaultKey: false)
        pendingDelete = identity
    }

    func commitDelete() {
        guard let identity = pendingDelete else { return }
        pendingDelete = nil
        do {
            let cleared = try AppStores.shared.identities.deleteIdentity(id: identity.id)
            DebugLog.shared.log(.connect,
                                "keys: deleted identity hosts=\(cleared.hosts.count) defaults=\(cleared.isDefaultKey)")
        } catch {
            errorText = "Couldn't delete the key: \(error.localizedDescription)"
        }
        reload()
    }

    /// Put the key's public line on the clipboard.
    func copyPublicKey(_ identity: Identity) {
        guard let text = publicKeyShareText(identity) else {
            errorText = "This key's public key couldn't be read."
            return
        }
        UIPasteboard.general.string = text
    }
}

/// Copy / Share / Rename / Delete, for the row context menu and the detail screen.
private struct SSHKeyActions: View {
    @ObservedObject var model: SSHKeysModel
    let identity: Identity

    var body: some View {
        Button { InputClickFeedback.play(); model.copyPublicKey(identity) } label: {
            Label("Copy Public Key", systemImage: "doc.on.doc")
        }
        if let text = publicKeyShareText(identity) {
            ShareLink(item: text) {
                Label("Share Public Key", systemImage: "square.and.arrow.up")
            }
        }
        Button { InputClickFeedback.play(); model.beginRename(identity) } label: {
            Label("Rename", systemImage: "pencil")
        }
        Button(role: .destructive) { InputClickFeedback.play(); model.beginDelete(identity) } label: {
            Label("Delete", systemImage: "trash")
        }
    }
}

/// One key: name, type and short fingerprint.
private struct SSHKeyRow: View {
    let identity: Identity

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(identity.displayName)
            Text("\(identity.algorithm.displayName) · \(Fingerprint(identity.fingerprint).truncated)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
    }
}

/// One key in full: the public key with Copy and Share, its details, Rename, Delete.
/// Owns its own model (and so its own dialogs); the list re-reads on return.
private struct SSHKeyDetailView: View {
    @StateObject private var model = SSHKeysModel()
    @State private var loaded = false
    let identityID: UUID
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if !loaded {
                Color.clear
            } else if let identity = model.identity(id: identityID) {
                List {
                    Section {
                        Text(publicKeyShareText(identity) ?? "This key's public key couldn't be read.")
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    } header: {
                        Text("Public Key")
                    } footer: {
                        Text("Add this line to ~/.ssh/authorized_keys on the server.")
                    }
                    Section {
                        LabeledContent("Type", value: identity.algorithm.displayName)
                        LabeledContent("Fingerprint") {
                            Text(Fingerprint(identity.fingerprint).sha256Display)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                        LabeledContent("Created",
                                       value: identity.createdAt.formatted(date: .abbreviated, time: .omitted))
                    }
                    Section { SSHKeyActions(model: model, identity: identity) }
                }
                .navigationTitle(identity.displayName)
            } else {
                // Deleted from this screen: go back to the list.
                Color.clear.onAppear { dismiss() }
            }
        }
        .sshKeyDialogs(model)
        .onAppear { model.reload(); loaded = true }
    }
}

private extension View {
    /// The Rename alert, Delete confirmation and error alert for `model`.
    func sshKeyDialogs(_ model: SSHKeysModel) -> some View {
        modifier(SSHKeyDialogs(model: model))
    }
}

private struct SSHKeyDialogs: ViewModifier {
    @ObservedObject var model: SSHKeysModel

    func body(content: Content) -> some View {
        content
            .alert("Rename Key", isPresented: Binding(
                get: { model.renaming != nil },
                set: { if !$0 { model.renaming = nil } }
            )) {
                TextField("Name", text: $model.renameText)
                Button("Save") { InputClickFeedback.play(); model.commitRename() }
                Button("Cancel", role: .cancel) { model.renaming = nil }
            }
            .confirmationDialog(
                "Delete “\(model.pendingDelete?.displayName ?? "")”?",
                isPresented: Binding(get: { model.pendingDelete != nil },
                                     set: { if !$0 { model.pendingDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) { InputClickFeedback.play(); model.commitDelete() }
                Button("Cancel", role: .cancel) { model.pendingDelete = nil }
            } message: {
                Text(identityDeleteMessage(model.pendingUsage))
            }
            .alert("SSH Keys", isPresented: Binding(
                get: { model.errorText != nil },
                set: { if !$0 { model.errorText = nil } }
            )) {
                Button("OK", role: .cancel) { model.errorText = nil }
            } message: {
                Text(model.errorText ?? "")
            }
    }
}
