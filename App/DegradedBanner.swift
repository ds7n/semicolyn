// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import SemicolynKit

/// Transient amber banner: control mode was declined/failed, running plain SSH.
struct DegradedBanner: View {
    let reason: DegradeReason
    let onDismiss: () -> Void
    @Environment(\.theme) private var theme

    private var message: String {
        switch reason {
        case .optedOut:        return "tmux control mode is off for this host — running as plain SSH."
        case .tmuxNotFound:    return "tmux not found — running as plain SSH."
        case .tooOld(let v):   return "tmux \(v.major).\(v.minor) is too old (need 3.0+) — running as plain SSH."
        case .couldNotStart:   return "Couldn't start tmux (check the session name) — running as plain SSH."
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message).font(.caption)
            Spacer()
            Button { InputClickFeedback.play(); onDismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .foregroundStyle(.black)
        .background(Color(theme.state.degraded).opacity(0.92))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
    }
}
