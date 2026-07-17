// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import SemicolynKit

/// The "Experimental (advanced, may be unreliable)" settings screen. Hosts the
/// alt-screen scroll mode radio and links to Diagnostics (relocated here).
struct ExperimentalSettingsView: View {
    // Read the shared store DIRECTLY rather than via `@EnvironmentObject`. An
    // `@EnvironmentObject` that was never injected is a `fatalError` by design, and
    // Settings is presented as a sheet/cover from several sites (in-session via
    // SessionView/KeybarView) that do NOT propagate the app-root injection, which crashed
    // the app when this screen opened. `AppStores.shared.terminalSettings` is a global
    // singleton, so this can never be missing and no presentation path can crash.
    @ObservedObject private var store = AppStores.shared.terminalSettings

    var body: some View {
        List {
            Section {
                // The picker's own label is hidden: the section header ("Alt-screen scroll")
                // is the single label for this control. Previously the Picker ALSO carried a
                // "Alt-screen scroll" title, so the inline picker's title row duplicated the
                // header and read like a tappable/selectable option row (it isn't). Hiding it
                // leaves just the four real, selectable mode rows under a plain header.
                Picker("Alt-screen scroll", selection: $store.settings.altScrollMode) {
                    Text("Line scroll (mouse wheel)").tag(AltScrollMode.wheel)
                    Text("Fallback (Page/arrow keys)").tag(AltScrollMode.pageKeysArrows)
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .onChange(of: store.settings.altScrollMode) { _, newValue in
                    DebugLog.shared.log(.lifecycle, "user-action: mode-switch \(newValue.rawValue)")
                }
            } header: {
                Text("Alt-screen scroll")
            } footer: {
                Text("""
                Line scroll: sends mouse-wheel events so full-screen apps (Claude, vim, less) \
                scroll one line at a time, like Blink. If an app does not respond to it, switch \
                to Fallback. Fallback: arrow keys for less/vim, PgUp/PgDn for AI CLIs (older method).
                """)
            }

            // Diagnostics inline on THIS screen (no nested navigation): DiagnosticsContent
            // renders its own sections directly into this List.
            DiagnosticsContent()
        }
        .navigationTitle("Experimental")
    }
}
