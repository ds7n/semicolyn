// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import UIKit
import LocalAuthentication
import SemicolynKit

/// Half-sheet SSH key picker opened from the Auth section's "Add SSH Key" button
/// (the model calls a key an `Identity`).
///
/// **Saved** lists existing keys, **Create** mints an Ed25519 key and **Import**
/// ingests an OpenSSH private key blob. After "Generate & Save" the sheet shows the
/// new public key with "Copy" (M-70) before closing. Settings > SSH Keys opens it
/// without the Saved tab.
struct IdentityPickerSheet: View {
    /// False hides the Saved tab (adding a key from Settings > SSH Keys).
    let showsSavedTab: Bool
    /// Called with the picked, generated or imported identity. A generated key is
    /// reported as soon as it is saved, so closing the public-key view any way keeps it.
    let onPick: (Identity) -> Void

    init(showsSavedTab: Bool = true, onPick: @escaping (Identity) -> Void) {
        self.showsSavedTab = showsSavedTab
        self.onPick = onPick
        _selectedTab = State(initialValue: showsSavedTab ? 0 : 1)
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    /// Selected tab index: 0 = Saved, 1 = Create, 2 = Import.
    @State private var selectedTab = 0
    /// The key just generated; non-nil shows its public key instead of the tabs.
    @State private var created: Identity?
    @State private var copied = false

    // All identities loaded once on appear.
    @State private var identities: [Identity] = []

    // Shared form state
    @State private var newName = ""
    @State private var biometricPolicy: BiometricPolicy = .afterUnlock
    @State private var importName = ""
    @State private var pastedKey = ""
    @State private var passphrase = ""
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            if let created {
                createdView(created)
            } else {
                tabs
            }
        }
        .onAppear {
            identities = (try? AppStores.shared.hosts.allIdentities()) ?? []
        }
    }

    private var tabs: some View {
        VStack(spacing: 0) {
            // Segmented tab picker
            Picker("", selection: $selectedTab) {
                if showsSavedTab { Text("Saved").tag(0) }
                Text("Create").tag(1)
                Text("Import").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .onChange(of: selectedTab) { _, _ in errorText = nil }

            // Tab content
            switch selectedTab {
            case 0:
                pickExistingTab
            case 1:
                createNewTab
            default:
                importExistingTab
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Add SSH Key")
                    .font(.headline)
                    .foregroundStyle(Color(theme.text.primary))
            }
            ToolbarItem(placement: .navigationBarLeading) {
                Button("Cancel") { InputClickFeedback.play(); dismiss() }
                    .foregroundStyle(Color(theme.accent.primary))
            }
        }
    }

    // MARK: - Created (public key + Copy)

    private func createdView(_ identity: Identity) -> some View {
        Form {
            Section {
                Text(publicKeyShareText(identity) ?? "This key's public key couldn't be read.")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                Button(copied ? "Copied" : "Copy") {
                    InputClickFeedback.play()
                    guard let text = publicKeyShareText(identity) else { return }
                    UIPasteboard.general.string = text
                    copied = true
                }
            } header: {
                Text("Public Key")
            } footer: {
                Text("Add this line to ~/.ssh/authorized_keys on the server. The private key stays in your Keychain.")
            }
        }
        .navigationTitle(identity.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { InputClickFeedback.play(); dismiss() }
            }
        }
    }

    // MARK: - Pick existing tab

    private var pickExistingTab: some View {
        Group {
            if identities.isEmpty {
                emptyState
            } else {
                List(identities, id: \.id) { identity in
                    IdentityRow(identity: identity, theme: theme) {
                        onPick(identity)
                        dismiss()
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Text("No saved keys yet.")
                .foregroundStyle(Color(theme.text.secondary))
            Button("Create a Key") { InputClickFeedback.play(); selectedTab = 1 }
                .buttonStyle(.bordered)
            Spacer()
        }
    }

    // MARK: - Create new tab (mint ed25519, iCloud Keychain)

    private var createNewTab: some View {
        Form {
            Section {
                TextField("Display name", text: $newName)
                biometricPolicyPicker
            } header: {
                Text("New SSH Key")
            } footer: {
                Text("Ed25519")
            }
            Section {
                Button("Generate & Save") { InputClickFeedback.play(); generate() }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            } footer: {
                if let errorText { Text(errorText).foregroundStyle(.red) }
            }
        }
    }

    // MARK: - Import existing tab

    private var importExistingTab: some View {
        Form {
            Section("Display name") { TextField("Display name", text: $importName) }
            Section("Private key (OpenSSH)") {
                TextEditor(text: $pastedKey).font(.caption.monospaced()).frame(minHeight: 120)
            }
            Section("Passphrase (if the key is encrypted)") {
                SecureField("Optional", text: $passphrase)
            }
            Section { biometricPolicyPicker }
            Section {
                Button("Import & Save") { InputClickFeedback.play(); importKey() }
                    .disabled(importName.trimmingCharacters(in: .whitespaces).isEmpty || pastedKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } footer: {
                if let errorText { Text(errorText).foregroundStyle(.red) }
            }
        }
    }

    private var biometricPolicyPicker: some View {
        Picker("Require \(biometryName)", selection: $biometricPolicy) {
            Text("Never").tag(BiometricPolicy.never)
            Text("Once per Unlock").tag(BiometricPolicy.afterUnlock)
            Text("Every Use").tag(BiometricPolicy.anyUse)
        }
    }

    /// "Touch ID" on Touch ID devices, otherwise "Face ID".
    private var biometryName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return context.biometryType == .touchID ? "Touch ID" : "Face ID"
    }

    private func generate() {
        errorText = nil
        do {
            let id = try AppStores.shared.identities.createGenerated(
                displayName: newName.trimmingCharacters(in: .whitespaces),
                biometricPolicy: biometricPolicy, now: Date())
            onPick(id)
            created = id
        } catch { errorText = friendly(error) }
    }

    private func importKey() {
        errorText = nil
        do {
            let id = try AppStores.shared.identities.importIdentity(
                displayName: importName.trimmingCharacters(in: .whitespaces),
                openssh: pastedKey, passphrase: passphrase.isEmpty ? nil : passphrase,
                biometricPolicy: biometricPolicy, now: Date())
            onPick(id); dismiss()
        } catch { errorText = friendly(error) }
    }

    /// User-facing message for a service error.
    private func friendly(_ error: Error) -> String {
        switch error as? IdentityServiceError {
        case .minting(let m): return "Couldn't read that key: \(m)"
        case nil: return "Couldn't save the key: \(error.localizedDescription)"
        }
    }
}

// MARK: - Identity row

/// A single row in the Pick-existing list showing the identity's display name,
/// truncated fingerprint, flavor badge, and biometric-policy glyph.
private struct IdentityRow: View {
    let identity: Identity
    let theme: Theme
    let onTap: () -> Void

    var body: some View {
        Button { InputClickFeedback.play(); onTap() } label: {
            HStack(spacing: 12) {
                // Display name + fingerprint
                VStack(alignment: .leading, spacing: 2) {
                    Text(identity.displayName)
                        .font(.body)
                        .foregroundStyle(Color(theme.text.primary))

                    Text(truncatedFingerprint)
                        .font(.caption.monospaced())
                        .foregroundStyle(Color(theme.text.secondary))
                }

                Spacer()

                // Flavor badge
                flavorBadge

                // Biometric-policy glyph
                biometricGlyph
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    // Show first 20 chars of the fingerprint string (e.g. "SHA256:AbCdEf123456789")
    private var truncatedFingerprint: String {
        let fp = identity.fingerprint
        guard fp.count > 20 else { return fp }
        return String(fp.prefix(20)) + "…"
    }

    private var flavorBadge: some View {
        Group {
            switch identity.flavor {
            case .iCloudKeychain:
                Text("iCloud Keychain")
                    .font(.caption2)
                    .foregroundStyle(Color(theme.accent.primary))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(theme.accent.primary).opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            case .secureEnclave:
                HStack(spacing: 2) {
                    Image(systemName: "bolt.fill")
                        .font(.caption2)
                    Text("Secure Enclave")
                        .font(.caption2)
                }
                .foregroundStyle(Color(theme.accent.highlight))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color(theme.accent.highlight).opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
    }

    @ViewBuilder
    private var biometricGlyph: some View {
        switch identity.biometricPolicy {
        case .never:
            // No glyph for .never per spec
            EmptyView()
        case .anyUse:
            Image(systemName: "touchid")
                .font(.body)
                .foregroundStyle(Color(theme.text.secondary))
        case .afterUnlock:
            Image(systemName: "lock.open")
                .font(.body)
                .foregroundStyle(Color(theme.text.secondary))
        }
    }
}
