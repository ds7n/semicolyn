// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// A value that is equal for two `TmuxSessionState`s that render identically, and differs
/// when the rendered output would change. Used to skip redundant tmux pane re-renders (the
/// control channel fires state updates far more often than the visible layout changes).
///
/// The rendered output is: the ACTIVE window's `visibleLayout` and `name` (the tab strip
/// renders window names), plus the window LIST (tab strip identity/order) and which window
/// is active. A change to a NON-active window's layout does not change what is on screen,
/// so it is intentionally excluded.
public struct RenderSignature: Equatable, Sendable {
    private let activeWindow: WindowID?
    private let windowIDs: [WindowID]
    private let activeName: String?
    private let activeVisibleLayout: PaneLayout?

    public init(_ state: TmuxSessionState) {
        self.activeWindow = state.activeWindow
        self.windowIDs = state.windows.map(\.id)
        let active = state.activeWindow.flatMap { state.window($0) }
        self.activeName = active?.name
        self.activeVisibleLayout = active?.visibleLayout
    }
}
