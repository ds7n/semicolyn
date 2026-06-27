// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import NeotildeKit

/// Tips & Gestures — documents the hardware-keyboard conventions Neotilde relies
/// on iOS for (Esc remap, Caps-as-Control) and lists the Cmd-shortcut map
/// (external-keyboard spec "Esc handling" / "Caps-as-Ctrl" / "Cmd-shortcut map").
/// Reached via `⌘?` or the Settings tree.
struct TipsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section("Hardware keyboard") {
                tip("No Esc key?",
                    "Most Magic Keyboards omit Esc. Map it in Settings → General → Keyboard → "
                    + "Hardware Keyboard → Modifier Keys → Caps Lock → Escape.")
                tip("Caps Lock as Control",
                    "In the same Modifier Keys screen, map Caps Lock → Control to reach ⌃C and "
                    + "friends without stretching.")
                tip("Held modifiers",
                    "Hold ⌃, ⌥, or ⇧ with a key — no sticky-tap dance like the on-screen keybar.")
                tip("Copy & paste",
                    "⌘C / ⌘V use the standard terminal copy-paste; the touch long-press menu still works too.")
            }

            Section("Keyboard shortcuts") {
                ForEach(Array(KeyboardCommandCatalog.all.enumerated()), id: \.offset) { _, spec in
                    HStack {
                        Text(glyphs(for: spec.chord))
                            .font(.system(.body, design: .monospaced))
                            .frame(minWidth: 56, alignment: .leading)
                        Text(spec.title).foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            }
        }
        .navigationTitle("Tips & Gestures")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
        }
    }

    private func tip(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.headline)
            Text(body).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    /// Renders a chord as modifier glyphs + the key, e.g. ⇧⌘P.
    private func glyphs(for chord: KeyboardChord) -> String {
        var out = ""
        if chord.control { out += "⌃" }
        if chord.option { out += "⌥" }
        if chord.shift { out += "⇧" }
        if chord.command { out += "⌘" }
        out += chord.input.uppercased()
        return out
    }
}
