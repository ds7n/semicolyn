// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import SemicolynKit

/// Settings → Appearance: how the terminal looks. Theme (`ThemeSection`), Font
/// (typeface, size, a sample line in both) and Cursor (style, blink). Behaviour
/// (scrollback, scrolling) lives in Terminal. Every change applies live.
struct AppearanceSettingsView: View {
    // Direct singleton reads, not `@EnvironmentObject` (see TerminalSettingsView).
    @ObservedObject private var store = AppStores.shared.terminalSettings
    @ObservedObject private var appearance = AppStores.shared.appearance

    private static let sample = "The quick brown fox 0O1l"

    var body: some View {
        List {
            ThemeSection()
            fontSection
            cursorSection
        }
        .navigationTitle("Appearance")
        // A Supporter-theme preview never outlives this screen: back to the saved theme.
        .onDisappear { appearance.previewThemeID = nil }
    }

    private var fontSection: some View {
        Section {
            NavigationLink {
                TerminalFontPickerView()
            } label: {
                LabeledContent("Typeface", value: store.settings.fontFace.displayName)
            }
            Stepper(value: $store.settings.fontSize, in: TerminalSettings.fontRange, step: 1) {
                LabeledContent("Size", value: "\(Int(store.settings.fontSize)) pt")
            }
            Text(Self.sample)
                .font(Font(TerminalFontProvider.shared.font(for: store.settings.fontFace,
                                                            size: CGFloat(store.settings.fontSize))))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .accessibilityLabel("Sample text")
        } header: {
            Text("Font")
        } footer: {
            Text("Pinch in a session to resize.")
        }
    }

    private var cursorSection: some View {
        Section {
            Picker("Style", selection: $store.settings.cursorStyle) {
                ForEach(SemicolynKit.CursorStyle.allCases, id: \.self) { style in
                    Text(style.displayName).tag(style)
                }
            }
            Toggle("Blink", isOn: $store.settings.cursorBlink)
        } header: {
            Text("Cursor")
        } footer: {
            Text("Programs can still change the cursor (for example vim's insert mode).")
        }
    }
}
