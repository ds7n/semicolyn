// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import SemicolynKit

/// A horizontal strip of tmux window tabs (temporary, until the Phase-4 keybar
/// window pill). Tap a tab to `select-window`; the active window is bronze-tinted.
struct WindowTabStrip: View {
    let windows: [TmuxWindow]
    let active: WindowID?
    let onSelect: (WindowID) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        // ScrollViewReader so we can keep the ACTIVE tab on-screen: with many windows the
        // strip scrolls past the active tab (device feedback 2026-07-16, swiping far enough
        // hid the tab you're on). On any `active` change we `scrollTo` it with `.center`,
        // which both guarantees visibility AND shows the neighbor tabs on each side (the
        // "always see it's not the last one" / vim-scrolloff intent). At the ends SwiftUI
        // clamps, so the first/last tab settles against the edge without extra math.
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(windows, id: \.id) { win in
                        let isActive = win.id == active
                        Button { InputClickFeedback.play(); onSelect(win.id) } label: {
                            Text(win.name.isEmpty ? "@\(win.id.raw)" : win.name)
                                .font(.caption.monospaced())
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(isActive ? Color(theme.accent.primary).opacity(0.18) : Color.clear)
                                .foregroundStyle(isActive ? Color(theme.accent.primary) : Color(theme.text.secondary))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .id(win.id)   // scroll target
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
            }
            .onChange(of: active) { _, newActive in
                guard let newActive else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(newActive, anchor: .center)
                }
            }
            .onAppear {
                // Center the active tab on first render too (e.g. reattach into a session
                // whose active window is deep in the list).
                if let active { proxy.scrollTo(active, anchor: .center) }
            }
        }
    }
}
