// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import SemicolynKit

@main
struct SemicolynApp: App {
    init() {
        // Register bundled + previously-imported Nerd Fonts with CoreText before any
        // TerminalView resolves its face, so `UIFont(name:)` finds them. `UIAppFonts`
        // also auto-registers the bundled files; this call additionally re-registers
        // user imports and is the single seam the font provider owns.
        TerminalFontProvider.shared.registerBundledFonts()
        TerminalFontProvider.shared.registerImportedFonts()

        // Configure diagnostics logging + remote sink from persisted settings at launch,
        // so remote streaming works from a cold start without first opening the
        // Diagnostics screen (fixes the "connected before visiting Settings → empty
        // stream" trap).
        DebugLog.shared.configureFromDefaults()
    }

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
            // Terminal preferences (font face/size) — the Terminal settings screen
            // and font picker bind to this via @EnvironmentObject.
            .environmentObject(AppStores.shared.terminalSettings)
    }
}
