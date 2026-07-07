// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import SemicolynKit

/// Amber banner: a Mosh session failed (bootstrap or a fast handshake failure), so
/// the session fell back to plain SSH. Persists until the user taps ✕ to dismiss —
/// it carries the real failure reason (from mosh's captured stderr via `onEnd`, or
/// `moshBranchOutcome`'s `.fallback(reason:)`), which the user needs time to read.
/// Free text (unlike `DegradedBanner`, bound to the tmux-specific `DegradeReason`).
struct MoshFallbackBanner: View {
    let reason: String
    let onDismiss: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(reason).font(.caption).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(action: onDismiss) { Image(systemName: "xmark") }.buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .foregroundStyle(.black)
        .background(Color(theme.state.degraded).opacity(0.92))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
    }
}
