// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import SemicolynKit

/// The single unified Settings screen. Reached from the host-list gear
/// (`.preConnect`) and long-press-Esc (`.inSession`). Sections that don't apply to
/// the current context (Keybar, Launcher pre-connect) render dimmed + disabled.
struct SettingsView: View {
    let context: SettingsContext
    @ObservedObject var keybarSettings: KeybarSettingsStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                row(.appearance, "Appearance", "paintpalette") { ThemePickerView() }
                row(.terminal, "Terminal", "terminal") { TerminalSettingsView() }
                row(.keybar, "Keybar", "keyboard") { KeybarEditorView(store: keybarSettings) }
                row(.launcher, "Launcher", "command") { MacroLibraryView(store: keybarSettings) }
                row(.defaults, "Connection Defaults", "slider.horizontal.3") { DefaultsEditorView() }
                row(.privacy, "Privacy", "hand.raised") { PrivacySettingsView() }
                row(.experimental, "Experimental", "flask") { ExperimentalSettingsView() }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { InputClickFeedback.play(); dismiss() }
                }
            }
        }
    }

    /// One Settings row. Disabled + dimmed when the gate says the section doesn't
    /// apply in the current context.
    @ViewBuilder
    private func row<Destination: View>(_ section: SettingsSection,
                                        _ title: String,
                                        _ symbol: String,
                                        @ViewBuilder destination: @escaping () -> Destination) -> some View {
        let enabled = SettingsGate.isEnabled(section, in: context)
        NavigationLink { destination() } label: {
            Label(title, systemImage: symbol)
                .opacity(enabled ? 1.0 : 0.4)   // dim when the section doesn't apply
        }
        .disabled(!enabled)
    }
}
