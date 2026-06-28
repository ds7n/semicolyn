// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import SemicolynKit

@main
struct SemicolynApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// Observes the appearance + Pro stores, resolves the active theme through the
/// pure gate, and injects it into the environment so every `@Environment(\.theme)`
/// consumer recolors live. (Before this, nothing injected `\.theme`, so the app
/// was stuck on the default — this is the wire that makes themes switchable.)
private struct RootView: View {
    @ObservedObject private var appearance = AppStores.shared.appearance
    @ObservedObject private var pro = AppStores.shared.pro

    var body: some View {
        HostListView()
            .environment(\.theme,
                         resolveTheme(selectedID: appearance.selectedThemeID,
                                      isPro: pro.isPro))
    }
}
