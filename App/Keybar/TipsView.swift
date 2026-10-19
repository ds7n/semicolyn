// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import SemicolynKit

/// Tips & Gestures: the touch gestures (as the gesture engine and keybar implement
/// them), the hardware-keyboard conventions Semicolyn relies on iOS for (Esc remap,
/// Caps-as-Control) and the Cmd-shortcut map (external-keyboard spec "Esc handling"
/// / "Caps-as-Ctrl" / "Cmd-shortcut map"). Reached via `⌘?` (a sheet, with Done)
/// or Settings > Tips & Gestures (pushed, no Done).
struct TipsView: View {
    /// Show the Done button: true when presented as its own sheet.
    var showsDoneButton = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section("Touch gestures") {
                tip("Switch tmux windows", "Swipe left or right on the terminal.")
                tip("Zoom a pane", "Long-press a pane to zoom it; long-press again to unzoom.")
                tip("Panes and windows",
                    "Long-press the arrow pad for Split Right, Split Down, New Window, Zoom and Close Pane.")
                tip("Select text", "Double-tap a word or triple-tap a line, then drag the handles.")
                tip("Bring the keyboard back", "Tap the terminal.")
                tip("Settings and the session menu",
                    "Long-press Esc. When the keybar is hidden, tap ≡ in the corner (long-press ≡ to show the keyboard).")
                tip("Second characters", "Swipe a key up or down to type its second character.")
                tip("Function keys", "Tap Fn for F1 to F12 once; tap it again to lock them on.")
                tip("Text size", "Pinch the terminal.")
            }

            Section("Hardware keyboard") {
                tip("No Esc key?",
                    "Most Magic Keyboards omit Esc. Map it in Settings → General → Keyboard → "
                    + "Hardware Keyboard → Modifier Keys → Caps Lock → Escape.")
                tip("Caps Lock as Control",
                    "In the same Modifier Keys screen, map Caps Lock → Control to reach ⌃C and "
                    + "friends without stretching.")
                tip("Held modifiers",
                    "Hold ⌃, ⌥, or ⇧ with a key; no sticky-tap dance like the on-screen keybar.")
                tip("Copy & paste",
                    "⌘C / ⌘V use the standard terminal copy-paste; the touch long-press menu still works too.")
            }

            KeyboardShortcutsSection()
        }
        .navigationTitle("Tips & Gestures")
        .toolbar {
            if showsDoneButton {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func tip(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.headline)
            Text(body).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// The hardware-keyboard shortcut list (`KeyboardCommandCatalog`), shared by Tips &
/// Gestures and Settings > Keyboard.
struct KeyboardShortcutsSection: View {
    var body: some View {
        Section("Keyboard shortcuts") {
            ForEach(Array(KeyboardCommandCatalog.all.enumerated()), id: \.offset) { _, spec in
                HStack {
                    Text(spec.chord.glyphs)
                        .font(.system(.body, design: .monospaced))
                        .frame(minWidth: 56, alignment: .leading)
                    Text(spec.title).foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
    }
}
