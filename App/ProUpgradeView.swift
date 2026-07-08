// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

/// Placeholder "Semicolyn Pro" screen — the Pro-gate seam's destination. Shows the
/// real perks copy from the pro-paid-scope spec; the purchase CTA is stubbed for
/// v1. The full StoreKit flow (purchase / restore / Family Sharing / Supporter
/// badge / alt icons) is a separate slice. A `#if DEBUG` unlock flips the stub
/// entitlement so the gate path is testable on the Simulator.
struct ProUpgradeView: View {
    @ObservedObject private var pro = AppStores.shared.pro

    var body: some View {
        List {
            Section {
                Text("Semicolyn is, and will stay, free to use in full. Pro is for people who want to support development. Buy it once; that's it.")
                    .font(.callout)
            }
            Section("What's included") {
                Label("Alternative app icons", systemImage: "app.badge")
                Label("Alternative color themes", systemImage: "paintpalette")
                Label("Supporter badge", systemImage: "sparkles")
            }
            Section {
                Button {
                    InputClickFeedback.play()
                    // Stub: real StoreKit purchase lands in the Pro slice.
                } label: {
                    Text("Unlock Semicolyn Pro — coming soon")
                        .frame(maxWidth: .infinity)
                }
                .disabled(true)
            }
            #if DEBUG
            Section("Debug") {
                Button(pro.isPro ? "Lock (debug)" : "Unlock (debug)") {
                    InputClickFeedback.play()
                    pro.setProForDebug(!pro.isPro)
                }
            }
            #endif
        }
        .navigationTitle("Semicolyn Pro")
    }
}
