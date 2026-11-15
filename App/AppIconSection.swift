// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import SemicolynKit

/// Settings → Appearance → App Icon: a grid of the visible icons (`visibleIcons`: only
/// the free ones on App Store builds). Supporter icons carry a badge while locked and
/// do nothing but a light tap when chosen; unlocked ones switch the home-screen icon.
struct AppIconSection: View {
    @ObservedObject private var pro = AppStores.shared.pro
    @State private var currentID = AppIconVariant.defaultIcon.id

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)

    var body: some View {
        let icons = visibleIcons(channel: pro.channel)
        Section {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(icons) { icon in
                    tile(icon)
                }
            }
            .padding(.vertical, 8)
        } header: {
            Text("App Icon")
        } footer: {
            if icons.contains(where: { $0.isSupporter }) && !pro.isPro {
                Text("Supporter icons unlock with Supporter preview.")
            }
        }
        .onAppear { currentID = AppIconSwitcher.current.id }
        .onChange(of: pro.isPro) { _, _ in
            // Locking may have put the primary icon back.
            Task { @MainActor in currentID = AppIconSwitcher.current.id }
        }
    }

    private func tile(_ icon: AppIconVariant) -> some View {
        let locked = icon.isSupporter && !pro.isPro
        let selected = icon.id == currentID
        return Button {
            if locked {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                return
            }
            InputClickFeedback.play()
            Task { @MainActor in
                await AppIconSwitcher.select(icon)
                currentID = AppIconSwitcher.current.id
            }
        } label: {
            VStack(spacing: 6) {
                Image(icon.previewAssetName)
                    .resizable()
                    .frame(width: 60, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 13.5, style: .continuous))
                    .overlay(alignment: .topTrailing) {
                        if locked {
                            Image(systemName: "sparkles")
                                .font(.caption2.weight(.semibold))
                                .padding(4)
                                .background(.thinMaterial, in: Circle())
                                .offset(x: 6, y: -6)
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if selected {
                            Image(systemName: "checkmark.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Color.accentColor)
                                .font(.body)
                                .offset(x: 6, y: 6)
                        }
                    }
                    .opacity(locked ? 0.6 : 1)
                Text(icon.displayName)
                    .font(.caption2)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(icon.displayName + (locked ? ", Supporter" : "") + (selected ? ", selected" : ""))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
