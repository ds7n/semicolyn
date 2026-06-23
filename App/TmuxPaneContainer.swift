// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import SwiftTerm
import GlymrKit

/// Renders the active tmux window's panes as a grid of SwiftTerm `TerminalView`s,
/// positioned from `paneRects(in:visibleLayout)`. The active pane gets a bronze
/// border and owns keyboard input; the rest are display-only. Pane output is
/// delivered by the view model via the registered `TerminalView` handles.
struct TmuxPaneContainer: UIViewRepresentable {
    let state: TmuxSessionState
    /// Called when a pane's `TerminalView` is created, so the VM can feed it bytes.
    let register: (PaneID, TerminalView) -> Void
    /// Called when a pane disappears, so the VM drops its handle.
    let unregister: (PaneID) -> Void
    /// Active-pane keystrokes/paste bytes → remote.
    let send: ([UInt8]) -> Void
    let theme: Theme

    func makeCoordinator() -> Coordinator { Coordinator(send: send) }

    func makeUIView(context: Context) -> ContainerView {
        let v = ContainerView()
        v.coordinator = context.coordinator
        return v
    }

    func updateUIView(_ uiView: ContainerView, context: Context) {
        uiView.apply(state: state, register: register, unregister: unregister,
                     borderColor: UIColor(Color(theme.accent.primary)))
    }

    /// Bridges SwiftTerm input from whichever pane is active to the VM.
    final class Coordinator: NSObject, TerminalViewDelegate {
        private let send: ([UInt8]) -> Void
        init(send: @escaping ([UInt8]) -> Void) { self.send = send }
        func send(source: TerminalView, data: ArraySlice<UInt8>) { send(Array(data)) }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}  // tmux owns geometry
        func scrolled(source: TerminalView, position: Double) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func bell(source: TerminalView) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }

    /// UIKit container that lays out one `TerminalView` per pane and tracks the set.
    final class ContainerView: UIView {
        weak var coordinator: Coordinator?
        private var panes: [PaneID: TerminalView] = [:]

        /// Cell metrics derived from a sample terminal's font (monospace → uniform cell).
        ///
        /// Uses `TerminalView.font` (confirmed public in SwiftTerm) for cell width via
        /// `"W".size(withAttributes:)`, and `f.lineHeight` for cell height. The
        /// brief's `getTerminal().rows`-based height is more accurate but requires
        /// `getTerminal()` to be part of the public API — cannot verify on Linux, so
        /// we use the conservative `f.lineHeight` fallback unconditionally for safety.
        private func cellSize(_ sample: TerminalView) -> (w: Double, h: Double) {
            let f = sample.font
            let w = Double("W".size(withAttributes: [.font: f]).width)
            let h = Double(f.lineHeight)
            return (w, h)
        }

        func apply(state: TmuxSessionState,
                   register: (PaneID, TerminalView) -> Void,
                   unregister: (PaneID) -> Void,
                   borderColor: UIColor) {
            guard let win = state.activeWindow, let window = state.window(win),
                  let layout = window.visibleLayout else { return }

            // Derive cell metrics from any existing pane (or a throwaway sample).
            let sample = panes.values.first ?? TerminalView(frame: bounds)
            let cell = cellSize(sample)
            let rects = paneRects(in: layout, cellWidth: cell.w, cellHeight: cell.h)
            let live = Set(rects.map(\.pane))

            // Remove panes tmux no longer reports.
            for (id, view) in panes where !live.contains(id) {
                view.removeFromSuperview(); unregister(id); panes[id] = nil
            }

            // Create/position each pane; border the active one.
            for rect in rects {
                let view = panes[rect.pane] ?? {
                    let t = TerminalView(frame: .zero)
                    t.terminalDelegate = coordinator
                    addSubview(t); panes[rect.pane] = t; register(rect.pane, t)
                    return t
                }()
                view.frame = CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
                let isActive = (rect.pane == window.activePane)
                view.layer.borderColor = borderColor.cgColor
                view.layer.borderWidth = isActive ? 1.5 : 0
                if isActive { view.becomeFirstResponder() }
            }
        }
    }
}
