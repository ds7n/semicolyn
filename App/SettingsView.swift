// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

/// Top-level Settings, presented as a sheet from the host list. v1 surfaces two
/// rows — Appearance and Privacy; it is the anchor for the future Settings tree
/// (Security, App preferences, About & Help — see the settings-sub-screens spec).
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                NavigationLink {
                    ThemePickerView()
                } label: {
                    Label("Appearance", systemImage: "paintpalette")
                }
                NavigationLink {
                    TerminalSettingsView()
                } label: {
                    Label("Terminal", systemImage: "terminal")
                }
                NavigationLink {
                    PrivacySettingsView()
                } label: {
                    Label("Privacy", systemImage: "hand.raised")
                }
                NavigationLink {
                    DiagnosticsSettingsView()
                } label: {
                    Label("Diagnostics", systemImage: "ladybug")
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { InputClickFeedback.play(); dismiss() }
                }
            }
        }
    }
}
