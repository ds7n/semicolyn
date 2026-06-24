// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import NeotildeKit

/// A horizontal strip of tmux window tabs (temporary, until the Phase-4 keybar
/// window pill). Tap a tab to `select-window`; the active window is bronze-tinted.
struct WindowTabStrip: View {
    let windows: [TmuxWindow]
    let active: WindowID?
    let onSelect: (WindowID) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(windows, id: \.id) { win in
                    let isActive = win.id == active
                    Button { onSelect(win.id) } label: {
                        Text(win.name.isEmpty ? "@\(win.id.raw)" : win.name)
                            .font(.caption.monospaced())
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(isActive ? Color(theme.accent.primary).opacity(0.18) : Color.clear)
                            .foregroundStyle(isActive ? Color(theme.accent.primary) : Color(theme.text.secondary))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
        }
    }
}
