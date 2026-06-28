// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import SemicolynKit

// MARK: - Prompt model

/// Identifies which host-key trust modal to present and carries the
/// data needed to render it. Used as `.sheet(item:)` source.
enum HostKeyPrompt: Identifiable, Equatable {
    case firstTrust(hostLabel: String, keyType: String, offered: String)
    case mismatch(hostLabel: String, keyType: String, stored: String, offered: String)

    /// Stable identifier per case + content — safe for `.sheet(item:)`.
    var id: String {
        switch self {
        case .firstTrust(let h, let k, let o):
            return "firstTrust|\(h)|\(k)|\(o)"
        case .mismatch(let h, let k, let s, let o):
            return "mismatch|\(h)|\(k)|\(s)|\(o)"
        }
    }
}

// MARK: - First-trust modal

/// "Trust this host?" — shown when no stored key exists for the offered
/// algorithm. Resolves via `onDecision`: `true` = trust & connect,
/// `false` = cancel (no entry written).
struct FirstTrustModal: View {
    let hostLabel: String
    let keyType: String
    let offered: String
    let onDecision: (Bool) -> Void

    @Environment(\.theme) private var theme
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            Text("Trust this host?")
                .font(.headline)
                .foregroundStyle(Color(theme.accent.primary))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // Host info
                    Text(hostLabel)
                        .font(.title2)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color(theme.text.primary))

                    Text(keyType)
                        .font(.subheadline)
                        .foregroundStyle(Color(theme.text.secondary))

                    // Fingerprint
                    let fp = Fingerprint(offered)
                    Text(expanded ? fp.full : fp.truncated)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(Color(theme.text.primary))
                        .textSelection(.enabled)
                        .onTapGesture { expanded.toggle() }
                        .animation(.default, value: expanded)

                    // Body copy — verbatim from spec
                    Text(
                        "Verify this matches what your administrator gave you, or the fingerprint shown by the server when you set it up."
                    )
                    .font(.subheadline)
                    .foregroundStyle(Color(theme.text.secondary))
                }
                .padding()
            }

            Divider()

            // Buttons
            HStack(spacing: 12) {
                Button {
                    onDecision(true)
                } label: {
                    Text("Trust & Connect")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(theme.accent.primary))

                Button {
                    onDecision(false)
                } label: {
                    Text("Cancel")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .foregroundStyle(Color(theme.text.secondary))
            }
            .padding()
        }
    }
}

// MARK: - Mismatch modal

/// "⚠ Host key changed" — shown when the offered key doesn't match the
/// stored entry. Resolves via `onDecision`: `true` = replace & connect
/// (only after a secondary destructive confirmation), `false` = cancel.
struct MismatchModal: View {
    let hostLabel: String
    let keyType: String
    let stored: String
    let offered: String
    let onDecision: (Bool) -> Void

    @Environment(\.theme) private var theme
    @State private var expandedStored = false
    @State private var expandedOffered = false
    @State private var showReplaceConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Red header strip
            Text("⚠ Host key changed")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color(theme.state.broken))

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // Host info
                    Text(hostLabel)
                        .font(.title2)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color(theme.text.primary))

                    Text(keyType)
                        .font(.subheadline)
                        .foregroundStyle(Color(theme.text.secondary))

                    // Body copy — verbatim from spec
                    Text(
                        "This may indicate a man-in-the-middle attack. Only continue if you know the host key legitimately changed (server reinstall, key rotation)."
                    )
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(Color(theme.text.primary))

                    // Stored fingerprint
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Last seen:")
                            .font(.caption)
                            .foregroundStyle(Color(theme.text.secondary))

                        let storedFp = Fingerprint(stored)
                        Text(expandedStored ? storedFp.full : storedFp.truncated)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(Color(theme.text.secondary))
                            .textSelection(.enabled)
                            .onTapGesture { expandedStored.toggle() }
                            .animation(.default, value: expandedStored)
                    }

                    // Offered fingerprint
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Now offering:")
                            .font(.caption)
                            .foregroundStyle(Color(theme.text.secondary))

                        let offeredFp = Fingerprint(offered)
                        Text(expandedOffered ? offeredFp.full : offeredFp.truncated)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(Color(theme.text.primary))
                            .textSelection(.enabled)
                            .onTapGesture { expandedOffered.toggle() }
                            .animation(.default, value: expandedOffered)
                    }
                }
                .padding()
            }

            Divider()

            // Buttons
            HStack(spacing: 12) {
                Button {
                    onDecision(false)
                } label: {
                    Text("Cancel")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .foregroundStyle(Color(theme.text.secondary))

                Button(role: .destructive) {
                    showReplaceConfirm = true
                } label: {
                    Text("Replace key & connect")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .confirmationDialog(
                    "Replace stored key?",
                    isPresented: $showReplaceConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Replace and connect", role: .destructive) {
                        onDecision(true)
                    }
                    Button("Cancel", role: .cancel) {
                        // Dismisses dialog only; no decision.
                    }
                } message: {
                    Text(
                        "The new key will replace the previous one for this host. If this change is unexpected, do not continue."
                    )
                }
            }
            .padding()
        }
    }
}
