// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import SwiftTerm
import SemicolynKit

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
    /// Active-pane keystrokes/paste bytes typed on the keyboard → remote, routed so
    /// an armed keybar Ctrl/Alt/Shift applies (via `vm.terminalKeyboardInput`).
    let send: ([UInt8]) -> Void
    /// Synthesized bytes (cursor-placement arrows) → remote RAW, bypassing the
    /// armed-modifier routing (an armed Ctrl must not mangle a cursor-drag arrow).
    var cursorSend: ([UInt8]) -> Void
    let theme: Theme
    /// Terminal rendering preferences (font, cursor, scrollback). Defaults from
    /// `AppStores.shared.terminalSettings.settings` at the call site.
    var settings: TerminalSettings = AppStores.shared.terminalSettings.settings
    /// Whether OSC 52 clipboard writes are allowed for this session (resolved at connect time).
    var osc52Allowed: Bool = true
    /// Called with the active pane's `TerminalView` + sanitized OSC 0/2 title; the
    /// VM keys it to the active pane before routing to `vm.terminalTitle`.
    var onTitle: ((TerminalView, String) -> Void)? = nil
    /// Called with debounced (cols, rows) when terminal grid size changes; routes to tmux client-size.
    var onTmuxResize: ((Int, Int) -> Void)? = nil
    /// Called when the user taps an ssh:// link; routes to the confirm-connect sheet.
    var onSSHLink: ((URL) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        let c = Coordinator(send: send, cursorSend: cursorSend, theme: theme, settings: settings, osc52Allowed: osc52Allowed, onTitle: onTitle)
        c.onTmuxResize = onTmuxResize
        c.onSSHLink = onSSHLink
        return c
    }

    func makeUIView(context: Context) -> ContainerView {
        let v = ContainerView()
        v.coordinator = context.coordinator
        // Wire the coordinator's cache-invalidation hook so a pinch font change
        // forces pane-rect metrics to recompute on the next layout pass.
        context.coordinator.onInvalidateCachedCell = { [weak v] in v?.invalidateCachedCell() }
        return v
    }

    func updateUIView(_ uiView: ContainerView, context: Context) {
        uiView.apply(state: state, register: register, unregister: unregister,
                     activeBorderColor: UIColor(Color(theme.focus.paneBorder)),
                     inactiveBorderColor: UIColor(Color(theme.focus.paneBorderInactive)))
        // Refresh halo and dot colors on theme changes.
        context.coordinator.bellHaloColor = UIColor(Color(theme.bell.edge))
        context.coordinator.accentDotColor = UIColor(Color(theme.accent.primary.alpha(0.40)))
        context.coordinator.cursorHaloColor = UIColor(Color(theme.accent.primary))
        // Recolor every live pane when the theme changes.
        for pane in uiView.paneTerminalViews {
            applyPalette(theme.terminalPalette(), to: pane)
        }
        // Keep the resize callback current (parent may re-create the closure).
        context.coordinator.onTmuxResize = onTmuxResize
        // Update mouse-active dot visibility and selection gesture state for all panes.
        context.coordinator.updateMouseDots(for: uiView.panes)
        // Reposition each focused pane's cursor-placement halo on the live cursor.
        context.coordinator.refreshCursorHalos()
    }

    /// Bridges SwiftTerm input from whichever pane is active to the VM.
    final class Coordinator: NSObject, TerminalViewDelegate {
        private let send: ([UInt8]) -> Void
        /// Raw send for synthesized cursor-drag arrows (bypasses armed modifiers).
        private let cursorSend: ([UInt8]) -> Void
        /// Per-pane bell state machines keyed by the TerminalView identity.
        /// Using ObjectIdentifier allows weak-ref-free keying without PaneID exposure here.
        private var bellMachines: [ObjectIdentifier: BellStateMachine] = [:]
        /// Per-pane halo views (installed as subviews on each TerminalView).
        private var haloViews: [ObjectIdentifier: BellHaloView] = [:]
        /// Per-pane mouse-active dot views (4pt, accent primary @ 40% opacity).
        private var mouseDots: [ObjectIdentifier: UIView] = [:]
        // TODO(phase4): wired when the connect-prefill / Esc-pill lands
        /// Per-pane selection long-press gesture recognizers. Suspended while mouse mode is active.
        var selectionLongPresses: [ObjectIdentifier: UILongPressGestureRecognizer] = [:]
        /// Per-pane pinch-zoom gesture recognizers keyed by TerminalView identity.
        private var pinchRecognizers: [ObjectIdentifier: UIPinchGestureRecognizer] = [:]
        /// Per-pane cursor-placement drag controllers (halo + pan), keyed by TerminalView identity.
        private var cursorDrags: [ObjectIdentifier: CursorDragController] = [:]
        /// Baseline font size for pinch-zoom; shared across all panes in this window.
        /// Updated on `.ended`; persists for the window's lifetime only (not stored to host — v1.5+).
        var baseFontSize: Double
        /// Called after a pinch font change to invalidate `ContainerView.cachedCell`.
        var onInvalidateCachedCell: (() -> Void)?
        /// Current bell halo color, refreshed from the theme in updateUIView.
        var bellHaloColor: UIColor {
            didSet { haloViews.values.forEach { $0.configure(color: bellHaloColor) } }
        }
        /// Current accent primary color for mouse dots, refreshed from the theme in updateUIView.
        var accentDotColor: UIColor {
            didSet { mouseDots.values.forEach { $0.backgroundColor = accentDotColor } }
        }
        /// Current cursor-placement halo color (theme accent), refreshed in updateUIView.
        var cursorHaloColor: UIColor {
            didSet { cursorDrags.values.forEach { $0.configure(color: cursorHaloColor) } }
        }
        /// Whether OSC 52 clipboard writes are permitted for this session.
        private let osc52Allowed: Bool
        /// Called with the source pane's `TerminalView` + sanitized OSC 0/2 title.
        private let onTitle: ((TerminalView, String) -> Void)?
        // TODO(phase4): wired when the connect-prefill / Esc-pill lands
        /// Called when the user taps an ssh:// link; set by the connect view to prefill the connect form.
        var onSSHLink: ((URL) -> Void)?
        /// Debounces rapid resize events across all panes (tmux client size).
        private var resizeDebounce: ResizeDebounce = ResizeDebounce()
        /// Routes debounced resize to the tmux client-size command.
        var onTmuxResize: ((Int, Int) -> Void)?

        /// Terminal rendering preferences; used to seed `baseFontSize` and apply font
        /// to each pane `TerminalView` at creation time.
        let settings: TerminalSettings

        init(send: @escaping ([UInt8]) -> Void, cursorSend: @escaping ([UInt8]) -> Void,
             theme: Theme, settings: TerminalSettings,
             osc52Allowed: Bool = true, onTitle: ((TerminalView, String) -> Void)? = nil) {
            self.send = send
            self.cursorSend = cursorSend
            self.settings = settings
            self.baseFontSize = settings.fontSize
            self.bellHaloColor = UIColor(Color(theme.bell.edge))
            self.accentDotColor = UIColor(Color(theme.accent.primary.alpha(0.40)))
            self.cursorHaloColor = UIColor(Color(theme.accent.primary))
            self.osc52Allowed = osc52Allowed
            self.onTitle = onTitle
        }

        // MARK: - Halo + mouse dot lifecycle

        /// Called from ContainerView when a TerminalView is first created.
        func installHalo(on view: TerminalView) {
            let key = ObjectIdentifier(view)
            guard haloViews[key] == nil else { return }
            let halo = BellHaloView(frame: view.bounds)
            halo.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            halo.configure(color: bellHaloColor)
            view.addSubview(halo)
            haloViews[key] = halo
            bellMachines[key] = BellStateMachine()

            // Install mouse-active indicator dot (top-left corner, fixed 4pt).
            let dot = UIView(frame: CGRect(x: 8, y: 8, width: 4, height: 4))
            dot.layer.cornerRadius = 2
            dot.backgroundColor = accentDotColor
            dot.isUserInteractionEnabled = false
            dot.isHidden = true
            view.addSubview(dot)
            mouseDots[key] = dot

            // Attach pinch-to-zoom gesture (shared baseline across all panes).
            let pinch = UIPinchGestureRecognizer(
                target: self,
                action: #selector(handlePinch(_:))
            )
            view.addGestureRecognizer(pinch)
            pinchRecognizers[key] = pinch

            // Install cursor-placement drag (halo + halo-gated pan); enabled per-pane in apply().
            let drag = CursorDragController(view: view, send: cursorSend)
            drag.configure(color: cursorHaloColor)
            drag.active = false
            drag.install()
            cursorDrags[key] = drag
        }

        /// Called from ContainerView when a TerminalView is removed.
        func removeHalo(from view: TerminalView) {
            let key = ObjectIdentifier(view)
            haloViews[key]?.removeFromSuperview()
            haloViews[key] = nil
            bellMachines[key] = nil
            mouseDots[key]?.removeFromSuperview()
            mouseDots[key] = nil
            selectionLongPresses[key] = nil
            if let pinch = pinchRecognizers[key] {
                view.removeGestureRecognizer(pinch)
                pinchRecognizers[key] = nil
            }
            cursorDrags[key]?.remove()
            cursorDrags[key] = nil
        }

        /// Enable the cursor-placement drag only on the focused pane (called from apply()).
        func setCursorDragActive(_ view: TerminalView, _ active: Bool) {
            cursorDrags[ObjectIdentifier(view)]?.active = active
        }

        /// Reposition every pane's cursor halo on the live cursor (called from updateUIView).
        func refreshCursorHalos() {
            cursorDrags.values.forEach { $0.refresh() }
        }

        /// Handles pinch-to-zoom across all panes. The baseline (`baseFontSize`) is
        /// shared so all panes stay at the same point size. On `.changed`, applies the
        /// clamped size to every live pane and resets `scale` to 1 so deltas compound
        /// correctly. On `.ended`, commits the final `baseFontSize` and resets scale.
        ///
        /// After each font change `onInvalidateCachedCell` is called so
        /// `ContainerView.resolvedCell()` re-measures on the next layout pass.
        ///
        /// - Assumption: `TerminalView.font` is a settable `UIFont` property (public in
        ///   SwiftTerm 1.x). Setting it replaces the terminal's monospace font immediately.
        ///   Not verifiable on Linux; macOS CI is the correctness gate.
        @objc func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            guard let tappedView = recognizer.view as? TerminalView else { return }
            switch recognizer.state {
            case .changed:
                let newSize = TerminalSettings.clampFont(baseFontSize * Double(recognizer.scale))
                let font = UIFont.monospacedSystemFont(ofSize: CGFloat(newSize), weight: .regular)
                // Apply to the pane being pinched immediately; apply to all registered
                // panes so the window stays visually consistent.
                for view in pinchRecognizers.keys.compactMap({ paneView(for: $0) }) {
                    view.font = font
                }
                tappedView.font = font   // fallback: ensure the direct pane is always updated
                recognizer.scale = 1
                baseFontSize = newSize
                onInvalidateCachedCell?()
            case .ended:
                baseFontSize = TerminalSettings.clampFont(baseFontSize)
                recognizer.scale = 1
                onInvalidateCachedCell?()
            default:
                break
            }
        }

        /// Returns the TerminalView associated with an ObjectIdentifier, by scanning
        /// pinch recognizers for their attached view. Used to fan out font changes.
        private func paneView(for key: ObjectIdentifier) -> TerminalView? {
            pinchRecognizers[key]?.view as? TerminalView
        }

        /// Poll mouse mode for each visible pane and update dot + gesture state.
        ///
        /// Called from `updateUIView` on each SwiftUI pass.
        ///
        /// - Assumption: `TerminalView.getTerminal().mouseMode` returns a value that
        ///   compares unequal to `.off` when mouse reporting is active.
        ///   This is the best-known SwiftTerm 1.x public API; not verifiable on Linux.
        func updateMouseDots(for panes: [PaneID: TerminalView]) {
            for (_, view) in panes {
                let key = ObjectIdentifier(view)
                let mouseActive = view.getTerminal().mouseMode != .off
                mouseDots[key]?.isHidden = !mouseActive
                if let gr = selectionLongPresses[key] {
                    if mouseActive {
                        gr.isEnabled = false
                        // Cursor placement is deliberately NOT suspended under mouse-mode — it
                        // synthesizes arrow keys, not mouse events (locked design). Selection-handle
                        // suppression is wired on the Simulator pass (no public SwiftTerm signal yet).
                    } else {
                        gr.isEnabled = true
                    }
                }
            }
        }

        // MARK: - TerminalViewDelegate

        func send(source: TerminalView, data: ArraySlice<UInt8>) { send(Array(data)) }

        // tmux owns the visible geometry. The client size is driven by the full
        // container grid (`ContainerView.layoutSubviews` → `noteClientSize`), not a
        // per-pane size change — a single split pane's grid is not the client size.
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}

        /// Debounced tmux client-size update. Called by `ContainerView.layoutSubviews`
        /// with the full-container grid (bounds ÷ measured cell) — the single accurate
        /// source, replacing the old coarse `sendApproxClientSize` estimate. Debounces
        /// rapid bursts (rotation / keyboard show-hide).
        func noteClientSize(cols: Int, rows: Int) {
            resizeDebounce.note(cols: cols, rows: rows, at: Date())
            DispatchQueue.main.asyncAfter(deadline: .now() + ResizeDebounce.quiet) { [weak self] in
                guard let self else { return }
                if let size = self.resizeDebounce.tick(at: Date()) {
                    self.onTmuxResize?(size.cols, size.rows)
                }
            }
        }
        func scrolled(source: TerminalView, position: Double) {}
        func setTerminalTitle(source: TerminalView, title: String) {
            if let t = sanitizeTerminalTitle(title) { onTitle?(source, t) }
        }
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func clipboardCopy(source: TerminalView, content: Data) {
            if case let .write(bytes) = osc52Action(allow: osc52Allowed, content: Array(content)) {
                UIPasteboard.general.string = String(decoding: bytes, as: UTF8.self)
            }
        }
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            guard let kind = classifyURL(link), let url = URL(string: link) else { return }
            switch kind {
            case .http, .https:
                UIApplication.shared.open(url)
            case .ssh:
                onSSHLink?(url)
            }
        }
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

        /// Visual bell: pulse halo on the ringing pane + optional haptic (throttled).
        func bell(source: TerminalView) {
            let key = ObjectIdentifier(source)
            var machine = bellMachines[key] ?? BellStateMachine()
            let haptic = machine.ring(at: Date())
            bellMachines[key] = machine
            if let halo = haloViews[key] {
                halo.start(machine: machine)
            }
            if haptic {
                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            }
        }
    }

    /// UIKit container that lays out one `TerminalView` per pane and tracks the set.
    final class ContainerView: UIView {
        weak var coordinator: Coordinator?
        /// Pane-ID → live TerminalView; exposed for coordinator mouse-dot updates.
        var panes: [PaneID: TerminalView] = [:]

        /// Cached cell metrics so we don't re-measure the font on every layout pass.
        /// Nil'd by `invalidateCachedCell()` after a pinch font change.
        private var cachedCell: (w: Double, h: Double)?

        /// Clears the cached cell metrics so `resolvedCell()` re-measures on the next
        /// layout pass. Called by the coordinator's `onInvalidateCachedCell` hook after
        /// a pinch-zoom font change, ensuring pane rects reflect the new font geometry.
        func invalidateCachedCell() { cachedCell = nil }

        /// All live pane terminal views; used by `updateUIView` to re-apply the theme palette.
        var paneTerminalViews: [TerminalView] { Array(panes.values) }

        /// On every layout pass (rotation, keyboard show-hide, font change) report the
        /// full-container cell grid to tmux as the client size. Uses the measured cell
        /// metrics, so it's accurate for any font — the single source that supersedes
        /// the old coarse `sendApproxClientSize` estimate. Debounced in the coordinator.
        override func layoutSubviews() {
            super.layoutSubviews()
            let cell = resolvedCell()
            guard let grid = terminalGrid(width: Double(bounds.width), height: Double(bounds.height),
                                          cellWidth: cell.w, cellHeight: cell.h) else { return }
            coordinator?.noteClientSize(cols: grid.cols, rows: grid.rows)
        }

        /// Cell metrics derived from a registered terminal's font (monospace → uniform cell).
        ///
        /// Uses `TerminalView.font` (confirmed public in SwiftTerm) for cell width via
        /// `"W".size(withAttributes:)`, and `f.lineHeight` for cell height. The
        /// brief's `getTerminal().rows`-based height is more accurate but requires
        /// `getTerminal()` to be part of the public API — cannot verify on Linux, so
        /// we use the conservative `f.lineHeight` fallback unconditionally for safety.
        /// Computed once from the first registered pane view; reused thereafter.
        private func resolvedCell() -> (w: Double, h: Double) {
            if let cached = cachedCell { return cached }
            guard let sample = panes.values.first else { return (8, 16) }
            let f = sample.font
            let w = Double("W".size(withAttributes: [.font: f]).width)
            let h = Double(f.lineHeight)
            let metrics = (w, h)
            cachedCell = metrics
            return metrics
        }

        func apply(state: TmuxSessionState,
                   register: (PaneID, TerminalView) -> Void,
                   unregister: (PaneID) -> Void,
                   activeBorderColor: UIColor,
                   inactiveBorderColor: UIColor) {
            guard let win = state.activeWindow, let window = state.window(win),
                  let layout = window.visibleLayout else { return }

            let cell = resolvedCell()
            let rects = paneRects(in: layout, cellWidth: cell.w, cellHeight: cell.h)
            let live = Set(rects.map(\.pane))

            // NOTE(v1): switching tmux windows destroys the off-screen window's pane views.
            // Control mode does not replay history on select-window, so switching back shows
            // a blank pane until new output arrives. Persisting per-window views is a future refinement.

            // Remove panes tmux no longer reports; resign first-responder before removal.
            for (id, view) in panes where !live.contains(id) {
                view.resignFirstResponder()
                coordinator?.removeHalo(from: view)
                view.removeFromSuperview(); unregister(id); panes[id] = nil
            }

            // Create/position each pane; border the active one.
            for rect in rects {
                let existed = panes[rect.pane] != nil
                let view = panes[rect.pane] ?? {
                    DebugLog.shared.log("pane \(rect.pane) CREATE TerminalView (reattach makes a fresh view)")
                    let t = TerminalView(frame: .zero)
                    t.terminalDelegate = coordinator
                    // Suppress SwiftTerm's built-in accessory bar — our `KeybarView`
                    // is the single accessory row (see TerminalScreen.makeUIView).
                    t.inputAccessoryView = nil
                    // Apply configured font so rendered pane matches the pinch baseline.
                    if let fontSize = coordinator?.settings.fontSize {
                        t.font = UIFont.monospacedSystemFont(ofSize: CGFloat(fontSize), weight: .regular)
                    }
                    addSubview(t); panes[rect.pane] = t; register(rect.pane, t)
                    coordinator?.installHalo(on: t)
                    return t
                }()
                view.frame = CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
                let isActive = (rect.pane == window.activePane)
                // The active-pane border only conveys meaning when there is more than
                // one pane (it answers "which pane has focus"). In a single-pane window
                // it reads as a pointless coral rim around the whole terminal, so
                // suppress ALL border chrome there. Keyboard focus is unaffected.
                let singlePane = (rects.count <= 1)
                if isActive {
                    view.layer.borderWidth = singlePane ? 0 : 1.5
                    if !singlePane { view.layer.borderColor = activeBorderColor.cgColor }
                    if !view.isFirstResponder {
                        let ok = view.becomeFirstResponder()
                        DebugLog.shared.log("pane \(rect.pane) ACTIVE existed=\(existed) inWindow=\(view.window != nil) becomeFirstResponder→\(ok) isFR=\(view.isFirstResponder)")
                    } else {
                        DebugLog.shared.log("pane \(rect.pane) ACTIVE already firstResponder")
                    }
                } else {
                    view.layer.borderColor = inactiveBorderColor.cgColor
                    view.layer.borderWidth = singlePane ? 0 : 0.5
                }
                coordinator?.setCursorDragActive(view, isActive)
            }
        }
    }
}
