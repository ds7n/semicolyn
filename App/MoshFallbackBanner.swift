// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import SemicolynKit

/// Transient amber banner: a Mosh bootstrap failed before handoff, so the session
/// fell back to plain SSH. Carries free text (unlike `DegradedBanner`, which is
/// bound to the tmux-specific `DegradeReason` enum) because the reason string comes
/// from `moshBranchOutcome`'s `.fallback(reason:)`.
struct MoshFallbackBanner: View {
    let reason: String
    let onDismiss: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(reason).font(.caption)
            Spacer()
            Button(action: onDismiss) { Image(systemName: "xmark") }.buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .foregroundStyle(.black)
        .background(Color(theme.state.degraded).opacity(0.92))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
    }
}
