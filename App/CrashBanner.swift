// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import SemicolynKit

/// The one banner that does NOT auto-dismiss (degraded-mode spec §"Mid-session
/// tmux crash recovery"): tmux died mid-session, the SSH transport is alive, and
/// the user is now on a fresh raw shell. Red, top of screen, persists until the
/// user picks an action or dismisses.
struct CrashBanner: View {
    let onReattach: () -> Void
    let onStartNew: () -> Void
    let onDismiss: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "xmark.octagon.fill")
                Text("tmux session ended — your shell is still running.").font(.caption).bold()
                Spacer()
            }
            HStack(spacing: 12) {
                // White pill on the red banner — force a DARK label so the text is
                // legible (the banner's .foregroundStyle(.white) would otherwise make
                // it white-on-white and invisible).
                Button("Reattach") { InputClickFeedback.play(); onReattach() }
                    .buttonStyle(.borderedProminent)
                    .tint(.white)
                    .foregroundStyle(Color(theme.state.broken))
                Button("Start new tmux") { InputClickFeedback.play(); onStartNew() }
                    .buttonStyle(.bordered)
                    .tint(.white)
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
