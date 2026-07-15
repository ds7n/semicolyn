// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import SemicolynKit

/// The "Experimental (advanced, may be unreliable)" settings screen. Hosts the
/// alt-screen scroll mode radio and links to Diagnostics (relocated here).
struct ExperimentalSettingsView: View {
    @EnvironmentObject private var store: TerminalSettingsStore

    var body: some View {
        List {
            Section {
                Picker("Alt-screen scroll", selection: $store.settings.altScrollMode) {
                    Text("Off (standard arrow keys)").tag(AltScrollMode.off)
                    Text("Auto (AI CLIs use Page keys)").tag(AltScrollMode.auto)
                    Text("Always Page keys").tag(AltScrollMode.alwaysPageKeys)
                    Text("Auto + window-title match (SSH/Mosh)").tag(AltScrollMode.autoPlusTitle)
                }
                .pickerStyle(.inline)
            } header: {
                Text("Alt-screen scroll")
            } footer: {
                Text("""
                Auto: Claude, Gemini, Codex, Qwen in tmux scroll with PgUp/PgDn instead of \
                arrows (which they read as prompt history). \
                Always: every full-screen app gets PgUp/PgDn, breaks line-scroll in less/vim. \
                Title match: also guesses the app from the window title on non-tmux sessions, \
                unreliable, titles are dynamic and may misfire.
                """)
            }

            Section {
                NavigationLink { DiagnosticsSettingsView() } label: {
                    Label("Diagnostics", systemImage: "ladybug")
                }
            }
        }
        .navigationTitle("Experimental")
    }
}
