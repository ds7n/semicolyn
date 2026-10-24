// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import SemicolynKit

/// The Theme section of Settings → Appearance (plus a DEBUG unlock section). Lists
/// the theme catalog with a palette swatch + a checkmark on the theme in use.
/// Supporter (Pro) themes show a "Supporter" badge while Pro is inactive; tapping one
/// previews it live (`previewThemeID`, never persisted) and leaving the Appearance
/// screen reverts to the saved theme (`AppearanceSettingsView`). There is no purchase
/// screen yet (the `ProStore` stub stays). Tapping a free theme applies and saves it.
struct ThemeSection: View {
    @ObservedObject private var appearance = AppStores.shared.appearance
    @ObservedObject private var pro = AppStores.shared.pro

    /// The saved descriptor actually rendered without a preview (gate-resolved): the
    /// checkmark follows this, not the raw selection, so a locked-but-selected theme
    /// shows the default as applied.
    private var appliedID: ThemeID {
        resolveDescriptor(selectedID: appearance.selectedThemeID, isPro: pro.isPro).id
    }

    /// Sections only (no `List`): the Appearance screen supplies the list.
    var body: some View {
        Group {
            Section {
                ForEach(Theme.catalog, id: \.id.raw) { descriptor in
                    row(for: descriptor)
                }
            } header: {
                Text("Theme")
            } footer: {
                if Theme.catalog.contains(where: { $0.isPro }) && !pro.isPro {
                    Text("Supporter themes are a thank-you for backing semicolyn. Coming soon.")
                }
            }
            #if DEBUG
            Section("Debug") {
                Button(pro.isPro ? "Lock Supporter themes (debug)" : "Unlock Supporter themes (debug)") {
                    InputClickFeedback.play()
                    pro.setProForDebug(!pro.isPro)
                }
            }
            #endif
        }
    }

    @ViewBuilder
    private func row(for descriptor: ThemeDescriptor) -> some View {
        let locked = descriptor.isPro && !pro.isPro
        let previewing = appearance.previewThemeID == descriptor.id
        Button {
            InputClickFeedback.play()
            if locked {
                // Toggle the live preview; nothing is saved.
                appearance.previewThemeID = previewing ? nil : descriptor.id
            } else {
                appearance.previewThemeID = nil
                appearance.selectedThemeID = descriptor.id
            }
        } label: {
            HStack(spacing: 12) {
                ThemeSwatch(theme: descriptor.theme)
                Text(descriptor.displayName)
                Spacer()
                if locked {
                    Label(previewing ? "Previewing" : "Supporter",
                          systemImage: previewing ? "eye" : "sparkles")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if descriptor.id == appliedID && appearance.previewThemeID == nil {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A small palette preview: accent + terminal-fg dots over the surface bg.
private struct ThemeSwatch: View {
    let theme: Theme
    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color(theme.surface.bg))
            .frame(width: 44, height: 28)
            .overlay(
                HStack(spacing: 3) {
                    Circle().fill(Color(theme.accent.primary)).frame(width: 10, height: 10)
                    Circle().fill(Color(theme.terminal.fg)).frame(width: 6, height: 6)
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color(theme.surface.line))
            )
    }
}
