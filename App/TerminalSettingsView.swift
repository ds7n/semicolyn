// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import SemicolynKit

/// Terminal settings: font size, font face, and how swiping scrolls full-screen apps.
struct TerminalSettingsView: View {
    // Read the shared store DIRECTLY rather than via `@EnvironmentObject`. An
    // `@EnvironmentObject` that was never injected is a `fatalError` by design, and
    // Settings is presented as a sheet/cover from several sites (in-session via
    // SessionView/KeybarView) that do NOT propagate the app-root injection, which crashed
    // the app when a screen read one. `AppStores.shared.terminalSettings` is a global
    // singleton, so this can never be missing and no presentation path can crash.
    @ObservedObject private var store = AppStores.shared.terminalSettings

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
            Section {
                // The section header is the single label; the inline picker's own title is
                // hidden so it doesn't read as one more selectable row.
                Picker("Scrolling in full-screen apps", selection: $store.settings.altScrollMode) {
                    Text("Mouse wheel (recommended)").tag(AltScrollMode.wheel)
                    Text("Arrow keys").tag(AltScrollMode.pageKeysArrows)
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .onChange(of: store.settings.altScrollMode) { _, newValue in
                    DebugLog.shared.log(.lifecycle, "user-action: mode-switch \(newValue.rawValue)")
                }
            } header: {
                Text("Scrolling in full-screen apps")
            } footer: {
                Text("How swiping scrolls in apps like vim and less. If an app doesn't scroll, try Arrow keys.")
            }
        }
        .navigationTitle("Terminal")
    }
}
