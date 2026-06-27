// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

/// Top-level Settings, presented as a sheet from the host list. v1 surfaces one
/// row — Appearance; it is the anchor for the future Settings tree (Security, App
/// preferences, About & Help — see the settings-sub-screens spec).
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
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
