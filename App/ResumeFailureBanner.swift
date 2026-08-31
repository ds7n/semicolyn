// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import SemicolynKit

/// Shown when a cold Mosh/ET resume reattach fails on launch. Mirrors `CrashBanner`
/// (the ET/-CC degrade-on-failure banner): red, top-of-screen, persists until the
/// user picks an action. The persisted record is already cleared; the VM holds the
/// reattach info in memory so Retry works for this banner's lifetime.
struct ResumeFailureBanner: View {
    let hostLabel: String
    let onRetry: () -> Void
    let onStartFresh: () -> Void
    let onBackToHosts: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "xmark.octagon.fill")
                Text("Couldn't resume \(hostLabel).").font(.caption).bold()
                Spacer()
            }
            HStack(spacing: 12) {
                // White pill on the red banner needs a DARK label to stay legible
                // (the banner's .foregroundStyle(.white) would make it invisible).
                Button("Retry") { InputClickFeedback.play(); onRetry() }
                    .buttonStyle(.borderedProminent)
                    .tint(.white)
                    .foregroundStyle(Color(theme.state.broken))
                Button("Start fresh") { InputClickFeedback.play(); onStartFresh() }
                    .buttonStyle(.bordered)
                    .tint(.white)
                Spacer()
                Button("Back to hosts") { InputClickFeedback.play(); onBackToHosts() }.buttonStyle(.plain)
            }
            .font(.caption)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .foregroundStyle(.white)
        .background(Color(theme.state.broken).opacity(0.95))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
    }
}

/// Lighter inline prompt (NOT the failure banner) shown on launch when the resumed
/// record is raw SSH: a raw session is client-side, so reconnecting is a fresh shell
/// and must be confirmed. "Reconnect to <host>?" with Reconnect / Not now.
struct ResumeRawPrompt: View {
    let hostLabel: String
    let onReconnect: () -> Void
    let onNotNow: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.clockwise.circle.fill")
            Text("Reconnect to \(hostLabel)?").font(.caption)
            Spacer()
            Button("Reconnect") { InputClickFeedback.play(); onReconnect() }
                .buttonStyle(.borderedProminent)
                .tint(Color(theme.accent.primary))
            Button("Not now") { InputClickFeedback.play(); onNotNow() }
                .buttonStyle(.plain)
        }
        .font(.caption)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .foregroundStyle(Color(theme.text.primary))
        .background(Color(theme.surface.panelHigh).opacity(0.96))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
    }
}
