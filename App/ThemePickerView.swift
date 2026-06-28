// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import SemicolynKit

/// Settings → Appearance → Theme. Lists the theme catalog with a palette swatch +
/// a checkmark on the currently *applied* theme. Pro themes show a ✦Pro badge when
/// Pro is inactive; tapping a locked theme routes to the upgrade screen instead of
/// applying. Selecting an unlocked theme mutates the store and the root recolors
/// live.
struct ThemePickerView: View {
    @ObservedObject private var appearance = AppStores.shared.appearance
    @ObservedObject private var pro = AppStores.shared.pro
    @State private var showingUpgrade = false

    /// The descriptor actually rendered right now (gate-resolved) — the checkmark
    /// follows this, not the raw selection, so a locked-but-selected theme shows
    /// the default as applied.
    private var appliedID: ThemeID {
        resolveDescriptor(selectedID: appearance.selectedThemeID, isPro: pro.isPro).id
    }

    var body: some View {
        List {
            ForEach(Theme.catalog, id: \.id.raw) { descriptor in
                row(for: descriptor)
            }
        }
        .navigationTitle("Theme")
        .navigationDestination(isPresented: $showingUpgrade) { ProUpgradeView() }
    }

    @ViewBuilder
    private func row(for descriptor: ThemeDescriptor) -> some View {
        let locked = descriptor.isPro && !pro.isPro
        Button {
            if locked {
                showingUpgrade = true
            } else {
                appearance.selectedThemeID = descriptor.id
            }
        } label: {
            HStack(spacing: 12) {
                ThemeSwatch(theme: descriptor.theme)
                Text(descriptor.displayName)
                Spacer()
                if locked {
                    Label("Pro", systemImage: "sparkles")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if descriptor.id == appliedID {
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
