// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import GlymrKit

/// Half-sheet inline identity picker opened from the Auth section's "+" button.
///
/// Plan 2 ships the **Pick existing** tab. **Create new** mints an ed25519 key
/// and **Import existing** ingests an OpenSSH private key blob.
struct IdentityPickerSheet: View {
    /// Called when the user selects an existing identity. The sheet dismisses itself.
    let onPick: (Identity) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    /// Selected tab index: 0 = Pick existing, 1 = Create new, 2 = Import existing.
    @State private var selectedTab = 0

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
            VStack(spacing: 0) {
                // Segmented tab picker
                Picker("", selection: $selectedTab) {
                    Text("Pick existing").tag(0)
                    Text("Create new").tag(1)
                    Text("Import existing").tag(2)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

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
                    Text("Add Identity")
                        .font(.headline)
                        .foregroundStyle(Color(theme.text.primary))
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Color(theme.accent.primary))
                }
            }
        }
        .onAppear {
            identities = (try? AppStores.shared.hosts.allIdentities()) ?? []
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
        VStack {
            Spacer()
            Text("No identities yet")
                .foregroundStyle(Color(theme.text.secondary))
            Spacer()
        }
    }

    // MARK: - Create new tab (mint ed25519, iCloud Keychain)

    private var createNewTab: some View {
        Form {
            Section("New ed25519 key") {
                TextField("Display name", text: $newName)
                biometricPolicyPicker
            }
            Section {
                Button("Generate & Save") { generate() }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            } footer: {
                if let errorText { Text(errorText).foregroundStyle(.red) }
            }
            secureEnclaveExplainer
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
                Button("Import & Save") { importKey() }
                    .disabled(importName.trimmingCharacters(in: .whitespaces).isEmpty || pastedKey.isEmpty)
            } footer: {
                if let errorText { Text(errorText).foregroundStyle(.red) }
            }
        }
    }

    private var biometricPolicyPicker: some View {
        Picker("Biometric", selection: $biometricPolicy) {
            Text("Never").tag(BiometricPolicy.never)
            Text("Per-unlock").tag(BiometricPolicy.afterUnlock)
            Text("Per-use").tag(BiometricPolicy.anyUse)
        }
    }

    /// SE deferral explainer (Phase 2b-i: iCloud Keychain only).
    private var secureEnclaveExplainer: some View {
        Section {
            Label("Secure Enclave keys arrive in a later update.", systemImage: "bolt.slash")
                .font(.caption).foregroundStyle(Color(theme.text.secondary))
        }
    }

    private func generate() {
        errorText = nil
        do {
            let id = try AppStores.shared.identities.createGenerated(
                displayName: newName.trimmingCharacters(in: .whitespaces),
                biometricPolicy: biometricPolicy, now: Date())
            onPick(id); dismiss()
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
        case nil: return "Couldn't save the identity: \(error.localizedDescription)"
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
        Button(action: onTap) {
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
