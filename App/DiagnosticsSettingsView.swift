// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

/// Settings → Diagnostics. Gates the on-screen debug log panel (the 🐞 overlay in a
/// connected session). Off by default; kept in the app so we can flip diagnostics on
/// to capture a trace on-device without a new build. The instrumentation itself
/// (`DebugLog`) always records cheaply; only the on-screen panel is gated.
struct DiagnosticsSettingsView: View {
    /// Shared key: read here and by `SessionView` to show/hide the 🐞 button.
    static let showDebugPanelKey = "diagnostics.showDebugPanel"
    @AppStorage(Self.showDebugPanelKey) private var showDebugPanel = false

    var body: some View {
        List {
            Section {
                Toggle("Show debug log panel", isOn: $showDebugPanel)
            } footer: {
                Text("Adds a 🐞 button in a connected session that opens a scrollable "
                     + "diagnostic log (connection, tmux attach, input routing) with a "
                     + "Copy button. For troubleshooting; leave off for normal use.")
            }
        }
        .navigationTitle("Diagnostics")
    }
}
