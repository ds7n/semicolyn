// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import SemicolynKit

/// The one banner that does NOT auto-dismiss (degraded-mode spec §"Mid-session
/// tmux crash recovery"). Today it is raised only by the Mosh exit path (crash or
/// clean exit), where the whole session is over, so the copy says the session
/// ended rather than claiming a shell is still running. Red, top of screen,
/// persists until the user reconnects (a fresh connect) or dismisses.
struct CrashBanner: View {
    let onReconnect: () -> Void
    let onDismiss: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "xmark.octagon.fill")
                Text("The session ended.").font(.caption).bold()
                Spacer()
            }
            HStack(spacing: 12) {
                // White pill on the red banner: force a DARK label so the text is
                // legible (the banner's .foregroundStyle(.white) would otherwise make
                // it white-on-white and invisible).
                Button("Reconnect") { InputClickFeedback.play(); onReconnect() }
                    .buttonStyle(.borderedProminent)
                    .tint(.white)
                    .foregroundStyle(Color(theme.state.broken))
                Spacer()
                Button("Dismiss") { InputClickFeedback.play(); onDismiss() }.buttonStyle(.plain)
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
