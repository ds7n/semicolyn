// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import SemicolynKit

/// Settings → Keyboard: the hardware-keyboard setting (moved here from Keybar) and
/// the hardware-keyboard shortcut list.
struct KeyboardSettingsView: View {
    @ObservedObject var store: KeybarSettingsStore

    var body: some View {
        List {
            Section {
                Toggle("Hide keybar when a hardware keyboard is connected",
                       isOn: Binding(get: { store.settings.hideKeybarWithHardwareKeyboard },
                                     set: { store.settings.hideKeybarWithHardwareKeyboard = $0 }))
            } footer: {
                Text("Hides the extra key row while a hardware keyboard is attached. Word suggestions stay visible.")
            }
            KeyboardShortcutsSection()
        }
        .navigationTitle("Keyboard")
    }
}
