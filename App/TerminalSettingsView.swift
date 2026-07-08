// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import SemicolynKit

/// Minimal Terminal settings: font size + font face picker. Anchor for the
/// (otherwise deferred) Terminal settings tree.
struct TerminalSettingsView: View {
    @EnvironmentObject private var store: TerminalSettingsStore

    var body: some View {
        List {
            Section("Font Size") {
                Slider(value: $store.settings.fontSize,
                       in: TerminalSettings.fontRange, step: 1) {
                    Text("Font Size")
                }
                Text("\(Int(store.settings.fontSize)) pt")
                    .foregroundStyle(.secondary)
            }
            Section("Font") {
                NavigationLink {
                    TerminalFontPickerView()
                } label: {
                    HStack {
                        Text("Typeface")
                        Spacer()
                        Text(store.settings.fontFace.displayName)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Terminal")
    }
}
