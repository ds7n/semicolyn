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
    /// Whether the active tmux session has more than one window (per-pane gesture
    /// controller's horizontal-drag-vs-scroll classifier).
    var onIsMultiWindowTmux: (() -> Bool)? = nil
    /// Horizontal-drag window switch (clamped, one per drag).
    var onSwitchWindow: ((Int) -> Void)? = nil
    /// Long-press on a pane: toggle zoom on the active pane.
    var onZoomActivePane: (() -> Void)? = nil
    /// Single tap on a pane: place the cursor at the tapped cell.
    var onPlaceCursor: ((TerminalView, Int, Int) -> Void)? = nil
    /// The connection view model — passed to each pane's inputAccessory-hosted keybar.
    var vm: ConnectionViewModel
    /// Keybar customization store — passed to each pane's inputAccessory-hosted keybar.
    var keybarSettings: KeybarSettingsStore = AppStores.shared.keybarSettings
    /// Whether a hardware keyboard is connected (drives the keybar's compact/hidden mode).
    var hardwareKeyboardConnected: Bool = false

    func makeCoordinator() -> Coordinator {
        let c = Coordinator(send: send, theme: theme, settings: settings, osc52Allowed: osc52Allowed, onTitle: onTitle)
        c.onTmuxResize = onTmuxResize
        c.onSSHLink = onSSHLink
        c.vm = vm
        c.keybarSettings = keybarSettings
        c.theme = theme
        c.hardwareKeyboardConnected = hardwareKeyboardConnected
        if let onIsMultiWindowTmux { c.onIsMultiWindowTmux = onIsMultiWindowTmux }
        if let onSwitchWindow { c.onSwitchWindow = onSwitchWindow }
        if let onZoomActivePane { c.onZoomActivePane = onZoomActivePane }
        if let onPlaceCursor { c.onPlaceCursor = onPlaceCursor }
        // Late-arriving alternate_on reply (pane already mounted by the time tmux
        // answers the attach-prime query): reconcile straight into modeTracker.
        // The early-arriving case (reply before mount) is handled at pane-creation
        // time in ContainerView.apply via vm.takeAltScreenOverride.
        vm.altScreenOverrideReady = { [weak c] pane, isAlt, view in
            c?.modeTracker.setAltScreenOverride(for: pane, isAlt: isAlt, terminal: view.getTerminal())
        }
        return c
    }

    func makeUIView(context: Context) -> ContainerView {
        let v = ContainerView()
        v.coordinator = context.coordinator
        context.coordinator.containerView = v
        // Wire the coordinator's cache-invalidation hook so a pinch font change
        // forces pane-rect metrics to recompute on the next layout pass.
        context.coordinator.onInvalidateCachedCell = { [weak v] in v?.invalidateCachedCell() }
        // Refresh mouse-dot visibility immediately on a mode transition, rather than
        // waiting for the next SwiftUI `updateUIView` pass. Also flip ownership of the
        // drag/tap axis for the transitioning pane: native scroll only in `.localScroll`.
        // `allowMouseReporting` is ON ONLY in `.mouseReporting` — NOT `.appOwnsInput`.
        // With it on in `.appOwnsInput`, SwiftTerm forwards the finger drag to the app as
        // SGR mouse events before our `handleScrollViewPan` can translate it to arrow keys,
        // so alt-screen panes (Claude/vim) don't scroll (device trace, build 44: a Claude
        // drag emitted 98+ SGR mouse sends, 0 arrows, and — because SwiftTerm consumed the
        // touch — 0 of our gesture logs fired). See the twin in TerminalScreen.
        context.coordinator.modeTracker.onChange = { [weak v] pane, mode in
            guard let v else { return }
            v.coordinator?.updateMouseDots(for: v.panes)
            if let pane, let view = v.panes[pane] {
                view.isScrollEnabled = (mode == .localScroll)
                view.allowMouseReporting = (mode == .mouseReporting)
                // Enable our alt-screen drag pan in lockstep with the isScrollEnabled
                // flip (owns the drag in `.appOwnsInput`, where the native pan is parked).
                v.coordinator?.setAltScreenPan(for: view, enabled: mode == .appOwnsInput)
            }
        }
        return v
    }

    func updateUIView(_ uiView: ContainerView, context: Context) {
        uiView.apply(state: state, register: register, unregister: unregister,
                     activeBorderColor: UIColor(Color(theme.focus.paneBorder)),
                     inactiveBorderColor: UIColor(Color(theme.focus.paneBorderInactive)))
        // Refresh halo and dot colors on theme changes.
        context.coordinator.bellHaloColor = UIColor(Color(theme.bell.edge))
        context.coordinator.accentDotColor = UIColor(Color(theme.accent.primary.alpha(0.40)))
        // Recolor every live pane when the theme changes.
        for pane in uiView.paneTerminalViews {
            applyPalette(theme.terminalPalette(), to: pane)
        }
        // Re-apply the font live to every pane when the user changes face/size in the
        // settings picker. Guard on the last SETTINGS-applied values (not the pinch
        // baseFontSize) so an in-progress pinch isn't clobbered each SwiftUI pass; a
        // deliberate settings change resets the shared pinch baseline.
        let coord = context.coordinator
        if settings.fontFace != coord.lastAppliedFace || settings.fontSize != coord.lastAppliedFontSize {
            let font = TerminalFontProvider.shared.font(for: settings.fontFace, size: CGFloat(settings.fontSize))
            for pane in uiView.paneTerminalViews { pane.font = font }
            coord.lastAppliedFace = settings.fontFace
            coord.lastAppliedFontSize = settings.fontSize
            coord.baseFontSize = settings.fontSize
            coord.onInvalidateCachedCell?()   // font change alters cell metrics → recompute pane rects
        }
        // Keep the resize callback current (parent may re-create the closure).
        context.coordinator.onTmuxResize = onTmuxResize
        // Keep the gesture-controller callbacks current (parent may re-create the closures).
        if let onIsMultiWindowTmux { context.coordinator.onIsMultiWindowTmux = onIsMultiWindowTmux }
        if let onSwitchWindow { context.coordinator.onSwitchWindow = onSwitchWindow }
        if let onZoomActivePane { context.coordinator.onZoomActivePane = onZoomActivePane }
        if let onPlaceCursor { context.coordinator.onPlaceCursor = onPlaceCursor }
        // Update mouse-active dot visibility and selection gesture state for all panes.
        context.coordinator.updateMouseDots(for: uiView.panes)
    }

    /// Bridges SwiftTerm input from whichever pane is active to the VM.
    final class Coordinator: NSObject, TerminalViewDelegate {
        private let send: ([UInt8]) -> Void
        /// Per-pane bell state machines keyed by the TerminalView identity.
        /// Using ObjectIdentifier allows weak-ref-free keying without PaneID exposure here.
        private var bellMachines: [ObjectIdentifier: BellStateMachine] = [:]
        /// Per-pane halo views (installed as subviews on each TerminalView).
        private var haloViews: [ObjectIdentifier: BellHaloView] = [:]
        /// Per-pane mouse-active dot views (4pt, accent primary @ 40% opacity).
        private var mouseDots: [ObjectIdentifier: UIView] = [:]
        /// Per-pane selection long-press gesture recognizers. Suspended while mouse mode is active.
        var selectionLongPresses: [ObjectIdentifier: UILongPressGestureRecognizer] = [:]
        /// Per-pane pinch-zoom gesture recognizers keyed by TerminalView identity.
        private var pinchRecognizers: [ObjectIdentifier: UIPinchGestureRecognizer] = [:]
        /// Per-pane gesture layer (replaces SwiftTerm's built-ins).
        private var gestureControllers: [ObjectIdentifier: TerminalGestureController] = [:]
        /// Fires if a committed switch's live window never arrives (stuck switch): restores
        /// the current window (snaps the slid-off card back).
        private var pendingSwitchTimeout: DispatchWorkItem?
        /// The window we are switching TO once tmux delivers it (armed at commit).
        private var pendingSwitchWindow: WindowID?
        /// Both-ready gate for the commit handoff (2026-07-18 timing fix): the live window
        /// swaps in only when the commit slide animation has finished (`switchAnimDone`) AND
        /// tmux has delivered the target window (`switchDelivered`). Whichever async event
        /// finishes LAST triggers `finishSwitchHandoffIfReady`. Fixes the race where tmux
        /// delivery (~120ms) reset the transform mid-slide (180ms) so no animation was seen.
        private var switchAnimDone = false
        private var switchDelivered = false
        /// Monotonic id for the current committed switch, so a STALE animation completion from
        /// a superseded switch can't touch the gate of its successor (whole-branch review C1,
        /// 2026-07-18). A rapid double-switch replaces switch A's `paneContentView` animation
        /// with switch B's; UIKit still fires A's completion (with `finished == false`), which
        /// would otherwise set `switchAnimDone = true` for B and let the gate finish B's handoff
        /// mid-slide - the very race this fix removes. Each `commitSwitchDrag` bumps this and
        /// captures it in the completion; the completion acts only if its captured id still
        /// matches. Also bumped by `discardCommittedSnapshot` / `failPendingSwitch` so a pending
        /// completion is invalidated when a switch is interrupted or times out.
        private var switchGeneration = 0
        /// Last `offset` (points) fed to `updateSwitchDrag`, so the per-frame live-drag
        /// render log fires only when the finger moves the content by ≥1pt (the `.render`
        /// "logged only on change" discipline (a 60fps drag must not drown the trace).
        /// Reset to `nil` at each drag's `.began` (`beginSwitchReveal`). This is the ONE
        /// permanent instrument that proves the live-drag transform is actually applied on
        /// device (the mechanism was previously never traced: see the render-wiring note
        /// on `updateSwitchDrag`).
        private var lastLoggedDragOffset: Double?
        /// The `ContainerView` this coordinator drives; set in `makeUIView`. Weak since
        /// `ContainerView` already holds a weak back-reference to this coordinator (avoid
        /// a retain cycle across the UIViewRepresentable boundary).
        weak var containerView: ContainerView?
        /// Callbacks supplied by the container/VM (set at construction, refreshed in
        /// `updateUIView` — mirrors `onTmuxResize`).
        var onIsMultiWindowTmux: () -> Bool = { false }
        var onSwitchWindow: (Int) -> Void = { _ in }
        var onZoomActivePane: () -> Void = { }
        var onPlaceCursor: (TerminalView, Int, Int) -> Void = { _, _, _ in }
        /// Tracks each pane's `InteractionMode`, recomputed from `PaneTerminalView`'s
        /// `bufferActivated`/`mouseModeChanged` overrides (event-driven, replaces the
        /// old render-time poll in `updateMouseDots`).
        let modeTracker = PaneModeTracker()
        /// Baseline font size for pinch-zoom; shared across all panes in this window.
        /// Updated on `.ended`; persists for the window's lifetime only (not stored to host — v1.5+).
        var baseFontSize: Double
        /// Last font face/size applied FROM SETTINGS (not a pinch). `updateUIView`
        /// re-applies to all panes when these differ from the incoming settings, so a
        /// picker change lands live without clobbering an in-progress pinch.
        var lastAppliedFace: TerminalFont
        var lastAppliedFontSize: Double
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
        /// Whether OSC 52 clipboard writes are permitted for this session.
        private let osc52Allowed: Bool
        /// Called with the source pane's `TerminalView` + sanitized OSC 0/2 title.
        private let onTitle: ((TerminalView, String) -> Void)?
        /// Called when the user taps an ssh:// link; set by the connect view to prefill the connect form.
        var onSSHLink: ((URL) -> Void)?
        /// Debounces rapid resize events across all panes (tmux client size).
        private var resizeDebounce: ResizeDebounce = ResizeDebounce()
        /// Routes debounced resize to the tmux client-size command.
        var onTmuxResize: ((Int, Int) -> Void)?

        /// Terminal rendering preferences; used to seed `baseFontSize` and apply font
        /// to each pane `TerminalView` at creation time.
        let settings: TerminalSettings

        /// Keybar-accessory inputs, set immediately after init in `makeCoordinator`.
        /// (IUO to keep `makeKeybarAccessory()` non-optional; always assigned before use.)
        var vm: ConnectionViewModel!
        var keybarSettings: KeybarSettingsStore = AppStores.shared.keybarSettings
        var theme: Theme = Theme.neonMidnight
        var hardwareKeyboardConnected: Bool = false

        init(send: @escaping ([UInt8]) -> Void,
             theme: Theme, settings: TerminalSettings,
             osc52Allowed: Bool = true, onTitle: ((TerminalView, String) -> Void)? = nil) {
            self.send = send
            self.settings = settings
            self.baseFontSize = settings.fontSize
            self.lastAppliedFace = settings.fontFace
            self.lastAppliedFontSize = settings.fontSize
            self.bellHaloColor = UIColor(Color(theme.bell.edge))
            self.accentDotColor = UIColor(Color(theme.accent.primary.alpha(0.40)))
            self.osc52Allowed = osc52Allowed
            self.onTitle = onTitle
            self.theme = theme
        }

        /// Build a keybar audio-feedback accessory for a pane's TerminalView. Each pane
        /// owns its own instance sharing the same `vm`; iOS shows the accessory of the
        /// first-responder pane, so the keybar follows the active pane via the existing
        /// per-pane `becomeFirstResponder` handling.
        func makeKeybarAccessory() -> KeybarInputAccessory {
            KeybarInputAccessory(vm: vm, keybarSettings: keybarSettings,
                                 theme: theme, hardwareKeyboardConnected: hardwareKeyboardConnected)
        }

        // MARK: - Halo + mouse dot lifecycle

        /// Called from ContainerView when a TerminalView is first created.
        /// `pane` is this pane's ID, captured by the installed gesture controller's
        /// `currentMode` closure so it can read `modeTracker.mode(for: pane)` directly
        /// (no reverse `paneID(for:)` lookup needed).
        func installHalo(on view: TerminalView, pane: PaneID) {
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

            // Panes start non-reporting; the per-pane value is then owned solely by
            // `modeTracker.onChange`, which flips it to true for `.mouseReporting` /
            // `.appOwnsInput` panes (fired once at prime time and on every mode
            // transition) so their events forward to the app instead of our gestures.
            view.allowMouseReporting = false

            // Replace SwiftTerm's built-in touch map with ours (per pane). Horizontal
            // drag switches tmux windows (clamped, one per drag); long-press zooms the
            // pane; tap places the cursor in this pane.
            MainActor.assumeIsolated {
                let controller = TerminalGestureController(
                    terminalView: view,
                    callbacks: .init(
                        isMultiWindowTmux: { [weak self] in self?.onIsMultiWindowTmux() ?? false },
                        onSwitchWindow: { [weak self] delta in
                            self?.onSwitchWindow(delta)   // tmux select-window (also used by esc-pill)
                        },
                        onLongPressZoom:   { [weak self] in self?.onZoomActivePane() },
                        onPlaceCursor:     { [weak self, weak view] col, row in
                            guard let view else { return }
                            self?.onPlaceCursor(view, col, row)
                        },
                        currentMode: { [weak self] in self?.modeTracker.mode(for: pane) ?? .localScroll },
                        applicationCursorKeys: { [weak view] in view?.getTerminal().applicationCursor ?? false },
                        altScrollDecision: { [weak self] in
                            MainActor.assumeIsolated {
                                guard let self else {
                                    return AltScrollDecision(keys: .wheel, mode: .wheel,
                                                             paneCommand: nil, reason: "wheel")
                                }
                                let mode = AppStores.shared.terminalSettings.settings.altScrollMode
                                // Read the runtime's COMPLETE context (not the
                                // renderablePanes-filtered `paneContexts`, which dropped the
                                // dragged pane and forced arrows: device trace 2026-07-16).
                                let cmd = self.vm.tmuxPaneCommand(pane)
                                let title = self.vm.terminalTitle
                                let decision = altScrollDecision(mode: mode, paneCommand: cmd,
                                                                 windowTitle: title, registry: .bundledDefault)
                                // The App prepends the pane id; the decider does not know it.
                                // This single line supersedes the old "altScroll decide" line;
                                // drag-begin logs decision.logLine, so this confirms the pane
                                // -> command resolution at snapshot time.
                                DebugLog.shared.log(.gesture,
                                    "alt-scroll pane=%\(pane.raw) \(decision.logLine)")
                                return decision
                            }
                        },
                        sendBytes: { [weak self] bytes in self?.send(bytes) },
                        hasSelection: { [weak view] in view?.selectionActive ?? false },
                        clearSelection: { [weak view] in view?.selectNone() },
                        onDragBeginSwitch: { [weak self] in
                            self?.beginSwitchReveal()
                        },
                        onDragUpdate: { [weak self] offset, exposed in
                            self?.updateSwitchDrag(offset: offset, exposed: exposed)
                        },
                        onDragCommit: { [weak self] delta in
                            self?.commitSwitchDrag(delta: delta)
                        },
                        onDragCancel: { [weak self] in
                            self?.cancelSwitchDrag()
                        }
                    )
                )
                gestureControllers[key] = controller
                // Re-enable pinch after the controller's sweep disabled pre-existing recognizers.
                pinch.isEnabled = true
                DebugLog.shared.log(.seed, "scroll:init isScrollEnabled=\(view.isScrollEnabled) nativePan=\(view.panGestureRecognizer.isEnabled) contentSize=\(view.contentSize) offset=\(view.contentOffset)")
            }
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
            MainActor.assumeIsolated {
                gestureControllers[key]?.detach()
            }
            gestureControllers[key] = nil
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
                // UIKit delivers gesture callbacks on the main thread; this @objc
                // selector is nonisolated, so hop onto the main actor to call the
                // @MainActor font provider.
                let font = MainActor.assumeIsolated {
                    TerminalFontProvider.shared.font(for: settings.fontFace, size: CGFloat(newSize))
                }
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
                // Persist the zoomed size so it survives reconnect (and updates the
                // Settings font-size slider) — mirrors the raw-terminal pinch handler.
                MainActor.assumeIsolated {
                    DebugLog.shared.log(.lifecycle, "user-action: zoom pinch → font=\(baseFontSize)")
                    let store = AppStores.shared.terminalSettings
                    if store.settings.fontSize != baseFontSize {
                        store.settings.fontSize = baseFontSize
                    }
                }
            default:
                break
            }
        }

        /// Returns the TerminalView associated with an ObjectIdentifier, by scanning
        /// pinch recognizers for their attached view. Used to fan out font changes.
        private func paneView(for key: ObjectIdentifier) -> TerminalView? {
            pinchRecognizers[key]?.view as? TerminalView
        }

        /// Update the mouse-dot *visual* for each visible pane from the event-driven
        /// `modeTracker` (no longer polls terminal state here — `PaneTerminalView`'s
        /// `bufferActivated`/`mouseModeChanged` overrides keep `modeTracker` current).
        /// `isScrollEnabled` / `allowMouseReporting` ownership flips live in
        /// `modeTracker.onChange` (see `makeUIView`), not here — this used to also
        /// reassign `allowMouseReporting` on every SwiftUI `updateUIView` pass, which
        /// would have clobbered the `onChange` flip's `.mouseReporting` case back to
        /// `false` on the very next render.
        ///
        /// Called from `updateUIView` on each SwiftUI pass.
        func updateMouseDots(for panes: [PaneID: TerminalView]) {
            for (id, view) in panes {
                let mode = modeTracker.mode(for: id)
                mouseDots[ObjectIdentifier(view)]?.isHidden = !(mode == .appOwnsInput || mode == .mouseReporting)
            }
        }

        /// Enable/disable a pane's alt-screen drag pan (the arrow-key synthesizer that
        /// owns the drag in `.appOwnsInput`). Routed through the Coordinator so the
        /// `gestureControllers` store stays private — the mode-transition handler and the
        /// pane-install path (different types, same file) both call this rather than
        /// reaching into the dictionary. Mirrors `updateMouseDots`.
        func setAltScreenPan(for view: TerminalView, enabled: Bool) {
            // The controller is `@MainActor`; this method is called from the (nonisolated)
            // Coordinator but always on the main thread (the `modeTracker.onChange` closure
            // and the layout-time pane-install path). Assume isolation, matching how
            // `removeHalo` invokes the controller's `detach()`.
            MainActor.assumeIsolated {
                gestureControllers[ObjectIdentifier(view)]?.setAltScreenPanEnabled(enabled)
            }
        }

        // MARK: - TerminalViewDelegate

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            // Diagnostic (build 28, key-repeat investigation) — see TerminalScreen.send.
            // Redacted the same way as the raw-SSH path: `.input` category (default OFF),
            // gated by the keystrokeContent toggle, with password lines never logged.
            // (Delegate callback is a nonisolated context; hop to the main actor.)
            MainActor.assumeIsolated {
                let logContent = UserDefaults.standard.bool(forKey: RemoteLogConfig.keystrokeContentKey)
                let isBackspace = data.count == 1 && (data.first == 0x7f || data.first == 0x08)
                let event = isBackspace ? "deleteBackward" : "insertText"
                let content = String(decoding: Array(data), as: UTF8.self)
                let isPwd = self.vm?.currentLineIsPassword() ?? false
                DebugLog.shared.log(.input, "key:\(keystrokeLogDecision(event: event, content: content, logContent: logContent, isPasswordLine: isPwd))")
            }
            send(Array(data))
        }

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

        // MARK: - Finger-drag window switch: reveal / update / commit / cancel

        /// Drag locked to the switch axis (drop-snapshot design: nothing to pre-warm; the card
        /// itself is what animates). If a committed-but-undelivered switch is still in flight
        /// (rapid re-drag), snap it back and invalidate it before this drag starts. Touches
        /// `@MainActor` state from this nonisolated Coordinator; wrapped in `assumeIsolated`
        /// (matches `setAltScreenPan` / `removeHalo`'s pattern for gesture-driven main-thread calls).
        func beginSwitchReveal() {
            MainActor.assumeIsolated {
                // A new drag interrupting a committed-but-undelivered switch must first snap that
                // switch's card back + invalidate it (C1), BEFORE clearPendingSwitch nils its state.
                discardCommittedSnapshot()
                clearPendingSwitch()
                lastLoggedDragOffset = nil   // fresh on-change baseline for this drag's render trace
                DebugLog.shared.log(.gesture, "switch-reveal begin")
            }
        }

        /// Live `.changed`: slide `paneContentView` with the finger and darken the exposed
        /// gap behind it. NO neighbor window is shown during the drag (pivot 2026-07-18:
        /// prep-don't-reveal); the pre-warmed snapshot is drawn only on commit. Wrapped in
        /// `assumeIsolated` for the same reason as `beginSwitchReveal`.
        func updateSwitchDrag(offset: Double, exposed: ExposedNeighbor) {
            MainActor.assumeIsolated {
                guard let content = containerView?.paneContentView else { return }
                content.transform = CGAffineTransform(translationX: CGFloat(offset), y: 0)
                updateCardDim(offset: offset)
                // Permanent `.render` instrument (logged-on-change, ≥1pt): prove the live-drag
                // transform is actually applied to `paneContentView` on device. `req` is the
                // offset the finger asked for; `tx` is read BACK off the view's transform right
                // after setting it: if `tx` ever diverges from `req`, something (a competing
                // frame/transform write, e.g. `layoutSubviews`) is stomping it between frames.
                let applied = Double(content.transform.tx)
                if lastLoggedDragOffset == nil || abs(offset - (lastLoggedDragOffset ?? 0)) >= 1 {
                    lastLoggedDragOffset = offset
                    DebugLog.shared.log(.render, decisionLine(
                        "render:drag-xform",
                        inputs: [("req", String(format: "%.1f", offset)),
                                 ("exposed", "\(exposed)")],
                        outputs: [("tx", String(format: "%.1f", applied)),
                                  ("frame.x", String(format: "%.1f", Double(content.frame.origin.x)))],
                        reason: abs(applied - offset) < 0.5 ? "applied" : "STOMPED"))
                }
            }
        }

        /// Ramp the UNIFORM card-dim overlay with drag progress (`GapDim.opacity`). The overlay
        /// is a child of `paneContentView`, so it rides the same transform and the dim travels
        /// with the finger (device 2026-07-19: the whole departing card darkens as it leaves,
        /// replacing the old side-gradient that dimmed the wrong edge). Assumes the caller is
        /// already on the main actor (called from within `updateSwitchDrag`'s `assumeIsolated`).
        private func updateCardDim(offset: Double) {
            guard let container = containerView else { return }
            let w = Double(container.bounds.width)
            let overlay = container.cardDimOverlay()
            let alpha = CGFloat(GapDim.opacity(offset: offset, width: w))
            overlay.alpha = alpha
            // Permanent `.render` instrument (audit 2026-07-19: the dim had ZERO logging, so a
            // "no dimming" report could not be diagnosed). Bounded to an active switch drag.
            // `assumeIsolated`: `DebugLog.shared.log` is `@MainActor` and Swift 6 checks isolation
            // per-method (matches every other main-actor touch in this Coordinator section).
            MainActor.assumeIsolated {
                DebugLog.shared.log(.render, decisionLine(
                    "render:card-dim",
                    inputs: [("offset", String(format: "%.0f", offset))],
                    outputs: [("alpha", String(format: "%.2f", Double(alpha)))],
                    reason: alpha > 0.01 ? "dim" : "clear"))
            }
        }

        /// Fade the card-dim overlay back to transparent (spring-back, commit-handoff, timeout).
        /// Main-actor caller (invoked from within existing `assumeIsolated` blocks).
        private func clearCardDim() {
            containerView?.cardDimOverlay().alpha = 0
        }

        /// Release past threshold: a paired page-turn. The current window slides OFF one
        /// edge while the PRE-WARMED snapshot of the new window slides IN from the opposite
        /// edge, in a single animation - both driven by the same `UIView.animate` so they
        /// stay in lockstep. The animation's completion sets `switchAnimDone` and asks the
        /// both-ready gate (`finishSwitchHandoffIfReady`) to finish the handoff, which also
        /// waits on tmux's delivery (`switchDelivered`, set by `completePendingSwitchIfNeeded`)
        /// so the live panes never swap in mid-slide (2026-07-18 timing fix: tmux delivery,
        /// ~120ms, used to arrive before the 180ms slide finished and reset the transform).
        func commitSwitchDrag(delta: Int) {
            MainActor.assumeIsolated {
                guard let content = containerView?.paneContentView,
                      let container = containerView,
                      let vm, let state = vm.tmuxState,
                      let active = state.activeWindow,
                      let dir = windowSlideDirection(delta: delta) else { cancelSwitchDrag(); return }
                // I1 (whole-branch review 2026-07-18): a switch whose target resolves to the
                // CURRENT window (degenerate neighbor, or a tmux select-window that would no-op)
                // never changes `state.activeWindow`, so the delivery handoff would never fire
                // and the covering snapshot would sit for the full 1.5s timeout. Treat it as a
                // spring-back instead - no cover, no tmux command.
                let target = vm.neighborWindow(of: active, delta: delta)
                guard let neighbor = target, neighbor != active else { cancelSwitchDrag(); return }

                let w = container.bounds.width
                let outX: CGFloat = (dir.out == .left) ? -w : w      // current window exits this edge

                // Fresh gate for this commit. Bump the generation so any still-pending
                // completion from a superseded switch (rapid double-switch) is ignored (C1).
                switchAnimDone = false
                switchDelivered = false
                switchGeneration &+= 1
                let generation = switchGeneration

                // Force the card-dim to full so the departing card reads fully dark by the time
                // it leaves (a fast flick may have left the drag-ramped alpha near zero).
                container.cardDimOverlay().alpha = CGFloat(GapDim.maxOpacity)

                pendingSwitchWindow = neighbor

                // Drop-snapshot design (2026-07-19): NO incoming preview. The current window (a
                // dimmed card) simply slides OFF `outX` over the container's own background; the
                // LIVE next window draws when tmux delivers (both-ready gate). A `-CC` neighbor
                // can have a different pane layout, so a captured preview never reliably matched
                // its size and flickered - dropping it removes that whole problem class.
                DebugLog.shared.log(.gesture,
                    "switch anim-start gen=\(generation) delta=\(delta) out=\(dir.out)")
                UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseOut], animations: {
                    content.transform = CGAffineTransform(translationX: outX, y: 0)
                }, completion: { [weak self] _ in
                    // Runs inside the outer `assumeIsolated` context (the enclosing
                    // `commitSwitchDrag` block), so main-actor state is reachable directly -
                    // NO inner `assumeIsolated` (matches the shipped `cancelSwitchDrag` pattern).
                    guard let self else { return }
                    // C1: ignore a STALE completion from a switch that was superseded (rapid
                    // double-switch) or interrupted/timed-out - it must not set the successor's
                    // `switchAnimDone` and let the gate finish B's handoff mid-slide.
                    guard generation == self.switchGeneration else {
                        DebugLog.shared.log(.gesture,
                            "switch anim-done gen=\(generation) STALE (cur=\(self.switchGeneration)) - ignored")
                        return
                    }
                    self.switchAnimDone = true
                    DebugLog.shared.log(.gesture, "switch anim-done gen=\(generation)")
                    self.finishSwitchHandoffIfReady()
                })

                onSwitchWindow(delta)   // tmux select-window (delivery flips `switchDelivered`)

                // 1.5s timeout backstop: a never-delivered switch restores the current. Cancel
                // any prior in-flight timeout before arming a new one (rapid re-commit race,
                // Task 7 review 2026-07-18).
                pendingSwitchTimeout?.cancel()
                let timeout = DispatchWorkItem { [weak self] in self?.failPendingSwitch() }
                pendingSwitchTimeout = timeout
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: timeout)
            }
        }

        /// Release short: spring the current window back to identity and clear the card-dim.
        /// Wrapped in `assumeIsolated` for the same reason as `beginSwitchReveal`.
        func cancelSwitchDrag() {
            MainActor.assumeIsolated {
                clearPendingSwitch()
                guard let container = containerView else { return }
                let content = container.paneContentView
                let dim = container.cardDimOverlay()
                UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseOut], animations: {
                    content.transform = .identity
                    dim.alpha = 0   // fade the card-dim back out together with the spring
                })
                DebugLog.shared.log(.gesture, "switch cancel -> spring back")
            }
        }

        /// Cancel any in-flight committed-switch handoff (its 1.5s timeout + pending window),
        /// so a spring-back or a new drag can't leave a stale timer that later yanks the pane.
        /// Mirrors the cancel-before-arm guard in `commitSwitchDrag`. Callers must invoke this
        /// from within their own `assumeIsolated` block (touches main-actor stored props but
        /// has no UIKit calls of its own, so it needs no wrapping here).
        private func clearPendingSwitch() {
            pendingSwitchTimeout?.cancel()
            pendingSwitchTimeout = nil
            pendingSwitchWindow = nil
        }

        /// Instantly restore the card (reset transform + clear dim) and invalidate a
        /// committed-but-undelivered switch, so a NEW drag can start from a clean state. With
        /// the drop-snapshot design there is no cover view to remove; the departing card may be
        /// mid-slide (transform off-screen) when a second drag begins, so we snap it back and
        /// bump the generation so the in-flight animation completion is ignored (C1). Main-actor
        /// caller (invoked from within `beginSwitchReveal`'s `assumeIsolated` block).
        private func discardCommittedSnapshot() {
            guard pendingSwitchWindow != nil else { return }
            switchAnimDone = false
            switchDelivered = false
            switchGeneration &+= 1   // C1: invalidate the interrupted switch's pending completion
            containerView?.paneContentView.transform = .identity
            clearCardDim()
        }

        /// Timeout: the committed switch never delivered. Restore the current content. Runs off a
        /// `DispatchWorkItem` fired on the main queue (`DispatchQueue.main.asyncAfter` in
        /// `commitSwitchDrag`), so it is already on the main thread; wrapped in `assumeIsolated`
        /// to match every other main-actor touch in this section.
        private func failPendingSwitch() {
            MainActor.assumeIsolated {
                pendingSwitchTimeout = nil
                pendingSwitchWindow = nil
                switchAnimDone = false
                switchDelivered = false
                switchGeneration &+= 1   // C1: invalidate this switch's pending animation completion
                containerView?.paneContentView.transform = .identity
                clearCardDim()
                DebugLog.shared.log(.gesture, "switch TIMEOUT -> restore current")
            }
        }

        /// The both-ready gate: complete the commit handoff only when the slide animation has
        /// finished AND tmux has delivered the target window. Called from BOTH the commit
        /// animation completion and the delivery path; the second caller (whichever is last)
        /// runs the teardown. No-op until both flags are set. Wrapped in `MainActor.assumeIsolated`
        /// like every other Coordinator method here: Swift 6 checks isolation PER-METHOD
        /// statically (it can't see that its callers are already on the main actor), and the
        /// `DebugLog.shared.log` calls are `@MainActor` - so the body needs the wrap even though
        /// the callers are wrapped. Nested `assumeIsolated` is a runtime executor assertion, safe
        /// to nest. (macOS CI 2026-07-19: unwrapped `log` here failed exactly as the
        /// `completePendingSwitchIfNeeded` fix predicted.)
        private func finishSwitchHandoffIfReady() {
            MainActor.assumeIsolated {
                guard switchAnimDone, switchDelivered else {
                    DebugLog.shared.log(.gesture,
                        "switch finish WAIT anim=\(switchAnimDone) delivered=\(switchDelivered)")
                    return
                }
                pendingSwitchTimeout?.cancel(); pendingSwitchTimeout = nil
                pendingSwitchWindow = nil
                switchAnimDone = false
                switchDelivered = false
                // The live next window is already mounted (by `apply(state:)`) at identity
                // UNDER the slid-off card. Reveal it by snapping the card transform back to
                // identity and clearing the dim - the card is now the live window.
                containerView?.paneContentView.transform = .identity
                clearCardDim()
                DebugLog.shared.log(.gesture, "switch finish (both-ready) -> live shown")
            }
        }

        /// Called from `apply(state:)` when the active window actually changed: RECORD that
        /// tmux delivered the target window, then let the both-ready gate decide whether to
        /// finish now (if the slide animation has also finished) or wait for it. No-op if no
        /// drag-switch is pending (e.g. an esc-pill switch, which sets no `pendingSwitchWindow`).
        /// Wrapped in `MainActor.assumeIsolated` (Swift 6 checks isolation per-method; nested
        /// wrap when called from `apply`'s own block is a runtime assertion, safe to nest).
        func completePendingSwitchIfNeeded(newActive: WindowID) {
            MainActor.assumeIsolated {
                guard pendingSwitchWindow != nil else {
                    // A switch that arrived without our drag (e.g. esc-pill): nothing to hand off.
                    return
                }
                switchDelivered = true
                // M1 (whole-branch review): tmux has delivered, so the switch WILL complete
                // (the animation completion is guaranteed to fire); cancel the 1.5s
                // never-delivered timeout now so it can't stomp a delivered-but-still-animating
                // switch during the both-ready WAIT window. (The finisher also cancels it, but
                // only once BOTH flags are set - this covers the delivered-first gap.)
                pendingSwitchTimeout?.cancel(); pendingSwitchTimeout = nil
                DebugLog.shared.log(.gesture,
                    "switch delivered active=@\(newActive.raw) animDone=\(switchAnimDone)")
                finishSwitchHandoffIfReady()
            }
        }
    }

    /// UIKit container that lays out one `TerminalView` per pane and tracks the set.
    final class ContainerView: UIView {
        weak var coordinator: Coordinator?
        /// Pane-ID → live TerminalView; exposed for coordinator mouse-dot updates.
        var panes: [PaneID: TerminalView] = [:]

        /// Wraps every pane subview so a later task can transform this ONE view to
        /// slide a whole tmux window (window-switch animation). Fills `bounds`;
        /// pane frames are computed in `apply(state:)` and are unchanged by this
        /// wrapper since it exactly covers the container's coordinate space.
        /// Added as a subview on first use (see `ensurePaneContentViewInstalled()`);
        /// `layoutSubviews` keeps its frame pinned to `bounds` but never touches its
        /// `.transform` (reserved for the future animation).
        let paneContentView = UIView()
        private var paneContentViewInstalled = false

        /// Installs `paneContentView` as the first (and only) content-hosting subview,
        /// lazily, the first time it's needed (mirrors `ContainerView` having no custom
        /// `init` today). Idempotent.
        private func ensurePaneContentViewInstalled() {
            guard !paneContentViewInstalled else { return }
            paneContentView.frame = bounds
            addSubview(paneContentView)
            paneContentViewInstalled = true
        }

        /// Uniform dim overlay that darkens the DEPARTING card itself as it drags off during a
        /// window switch (device 2026-07-19: replaces the old side-gradient gap-dim, which
        /// darkened the exposed edge the user drags AWAY from and read backwards). Added as a
        /// subview OF `paneContentView`, so it rides the same transform and the dim travels with
        /// the finger. Solid black; the Coordinator ramps its `.alpha` 0 -> `GapDim.maxOpacity`
        /// with drag distance. Transparent at rest.
        let cardDimView = UIView()
        private var cardDimInstalled = false

        /// Install `cardDimView` as the TOP subview of `paneContentView` (so it dims the panes
        /// beneath it) pinned to `paneContentView.bounds`. Idempotent. Requires
        /// `paneContentView` to be installed first (its parent).
        private func ensureCardDimInstalled() {
            guard !cardDimInstalled else { return }
            ensurePaneContentViewInstalled()
            cardDimView.frame = paneContentView.bounds
            cardDimView.isUserInteractionEnabled = false
            cardDimView.alpha = 0
            cardDimView.backgroundColor = .black
            paneContentView.addSubview(cardDimView)   // on top of the panes, inside the card
            cardDimInstalled = true
        }

        /// The card-dim overlay view, for the Coordinator to ramp `.alpha`.
        func cardDimOverlay() -> UIView {
            ensureCardDimInstalled()
            return cardDimView
        }

        /// Cached cell metrics so we don't re-measure the font on every layout pass.
        /// Nil'd by `invalidateCachedCell()` after a pinch font change.
        private var cachedCell: (w: Double, h: Double)?

        /// Last-applied render signature. `apply(state:)` skips the (expensive) pane re-layout
        /// when the new state's signature matches — the SwiftUI `updateUIView` pass fires far
        /// more often than the rendered layout actually changes (the render storm).
        private var lastRenderSignature: RenderSignature?

        /// The active window as of the last `apply` that reached the change-detect at the
        /// end of the method. Compared against `state.activeWindow` there to decide whether
        /// a pending finger-drag switch handoff should complete (see `completePendingSwitchIfNeeded`).
        private var previousActiveWindow: WindowID?

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
            // Keep the pane-hosting wrapper pinned to our bounds on every layout pass
            // (rotation, keyboard show-hide, font change) BEFORE pane frames are
            // computed below. Frame only - `.transform` is left alone (a later task
            // animates it for the window-switch slide).
            ensurePaneContentViewInstalled()
            // Pin the pane-hosting wrapper to our bounds on every layout pass (rotation,
            // keyboard show-hide, font change). CRUCIAL (device root-cause 2026-07-19): when a
            // live window-switch drag has set a non-identity `.transform` on this view, we must
            // NOT write `.frame` - UIKit derives `frame` THROUGH the transform, so `frame =
            // bounds` back-computes bounds/center in a way that cancels the drag translation
            // (trace: tx=-288 while frame.x=-0.3, so the window never visibly moved). Under the
            // -CC render storm `layoutSubviews` fires ~60x/sec, so this fought the transform on
            // every frame. Per the UIKit contract, position a transformed view via `bounds` +
            // `center` (both applied INDEPENDENTLY of the transform) and leave `frame` alone; use
            // the plain `frame = bounds` only when at rest (identity transform).
            let dragActive = !paneContentView.transform.isIdentity
            if dragActive {
                paneContentView.bounds = CGRect(origin: .zero, size: bounds.size)
                paneContentView.center = CGPoint(x: bounds.midX, y: bounds.midY)
            } else {
                paneContentView.frame = bounds
            }
            // Permanent `.render` instrument: confirm the transform SURVIVES this layout pass now.
            // Before the fix this logged `FRAME-STOMPED-XFORM`; it should now always be
            // `transform-preserved` while a drag is active. Silent at rest (identity transform).
            if dragActive {
                DebugLog.shared.log(.render, decisionLine(
                    "render:layout-vs-xform",
                    inputs: [("tx", String(format: "%.1f", Double(paneContentView.transform.tx))),
                             ("bounds.w", String(format: "%.0f", Double(bounds.width)))],
                    outputs: [("frame.x", String(format: "%.1f", Double(paneContentView.frame.origin.x)))],
                    reason: "transform-preserved(bounds+center)"))
            }
            // Keep the card-dim overlay pinned to the card (paneContentView) on every pass,
            // and ALWAYS on top of it: a window switch creates new pane subviews via
            // `paneContentView.addSubview` AFTER install, which would otherwise stack them above
            // the dim and leave it darkening nothing during the slide (review 2026-07-19).
            ensureCardDimInstalled()
            cardDimView.frame = paneContentView.bounds
            paneContentView.bringSubviewToFront(cardDimView)
            let cell = resolvedCell()
            guard let grid = terminalGrid(width: Double(bounds.width), height: Double(bounds.height),
                                          cellWidth: cell.w, cellHeight: cell.h) else { return }
            // Sizing diagnostics (#4 keybar-height / #5 col-count, 2026-07-15). Log the
            // full geometry at the grid-computation boundary so a device trace can prove
            // whether the container bounds already exclude the keybar (inputAccessoryView)
            // area, or whether the grid is computed from pre-keyboard-avoidance bounds.
            // `si` = safeAreaInsets; a nonzero `.bottom` = the system reserved space (home
            // indicator / keyboard). `kb` = the active pane's keybar accessory height.
            let si = safeAreaInsets
            let kbH = firstResponderKeybarHeight()
            // Logged under `.tmux` (default-ON) rather than `.keybar` (off): the
            // grid/client-size mismatch (#D: we send tmux 80 cols while the window is
            // laid out at 89) is a tmux-sizing concern, and it must capture on a device
            // build without a manual toggle.
            DebugLog.shared.log(.tmux,
                "sizing:tmux bounds=\(Int(bounds.width))x\(Int(bounds.height)) si=(t\(Int(si.top)),b\(Int(si.bottom))) cell=\(String(format: "%.1f", cell.w))x\(String(format: "%.1f", cell.h)) kbH=\(String(format: "%.1f", kbH)) grid=\(grid.cols)x\(grid.rows)")
            coordinator?.noteClientSize(cols: grid.cols, rows: grid.rows)
        }

        /// Sizing-diagnostic helper: the keybar (`inputAccessoryView`) height of whichever
        /// pane is currently first responder (iOS shows exactly that pane's accessory).
        /// Returns -1 if no pane is first responder (keyboard down → no accessory shown).
        /// Reads `KeybarInputAccessory.intrinsicContentSize` so it reflects the live
        /// self-sized height, not the seed. Cheap; used only inside the gated `.keybar` log.
        private func firstResponderKeybarHeight() -> CGFloat {
            for view in panes.values where view.isFirstResponder {
                if let acc = view.inputAccessoryView as? KeybarInputAccessory {
                    return acc.intrinsicContentSize.height
                }
            }
            return -1
        }

        /// Cell metrics (monospace → uniform cell), used both to compute the container
        /// grid we report to tmux as the client size AND to place panes from the tmux
        /// layout (`paneRects`).
        ///
        /// The cell is read back from SwiftTerm's own `cellDimension` via
        /// `getOptimalFrameSize() ÷ (cols, rows)` (see body) so our reported grid matches
        /// exactly what SwiftTerm renders. A prior fix derived the cell from the font
        /// (`"W".size()` + `lineHeight`) to break the 1×N-collapse feedback loop, but that
        /// formula differs from SwiftTerm's (`ceil("W".width·scale)/scale`,
        /// `ceil(ascent+descent+leading)·lineSpacing`), leaving the reported grid 1–2 cols
        /// off. Reading SwiftTerm's cell back is both exact and loop-immune — the old
        /// collapse came from `viewBounds ÷ cols` (bounds and cols disagree mid-zoom);
        /// here the `cols` cancels out of `cellDimension·cols ÷ cols`, so zoom state can't
        /// poison it. Cached until the font changes (`invalidateCachedCell()` on a pinch).
        private func resolvedCell() -> (w: Double, h: Double) {
            if let cached = cachedCell { return cached }
            // Simplest correct source: ask SwiftTerm for the cell it actually renders
            // with. `getOptimalFrameSize()` returns `cellDimension × (cols, rows)`, so
            // dividing back out by `cols`/`rows` recovers SwiftTerm's own snapped cell
            // EXACTLY — no re-deriving it from `"W".size()` + lineHeight, which differs
            // from SwiftTerm's `ceil("W".width·scale)/scale` and `ceil(ascent+descent+
            // leading)`; that mismatch left the reported grid 1–2 cols off.
            //
            // This is NOT the old `bounds ÷ cols` readback that caused the 1×N collapse:
            // there the numerator was the pane's *view bounds* (which disagree with cols
            // during a zoom transient → poisoned cell). Here numerator and denominator
            // are `cellDimension·cols` and `cols` — the `cols` cancels, yielding
            // `cellDimension` regardless of zoom state. Loop-immune by construction.
            if let pane = panes.values.first {
                let optimal = pane.getOptimalFrameSize()
                let term = pane.getTerminal()
                let cols = Double(term.cols), rows = Double(term.rows)
                if cols > 0, rows > 0 {
                    let w = Double(optimal.width) / cols
                    let h = Double(optimal.height) / rows
                    if w > 0, h > 0 {
                        cachedCell = (w: w, h: h)
                        return (w: w, h: h)
                    }
                }
            }
            // Before any pane exists we can't ask SwiftTerm yet; fall back to the
            // configured font's measurement (left UNcached so the next pass upgrades to
            // SwiftTerm's real cell). Pure font math — no bounds, no cols — so a zoomed
            // pane can never corrupt this path either.
            let font = coordinator.map { TerminalFontProvider.shared.font(for: $0.settings.fontFace,
                                                                          size: CGFloat($0.baseFontSize)) }
                ?? UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
            let w = Double("W".size(withAttributes: [.font: font]).width)
            let h = Double(font.lineHeight)
            guard w > 0, h > 0 else { return (8, 16) }
            return (w: w, h: h)
        }

        func apply(state: TmuxSessionState,
                   register: (PaneID, TerminalView) -> Void,
                   unregister: (PaneID) -> Void,
                   activeBorderColor: UIColor,
                   inactiveBorderColor: UIColor) {
            // SwiftUI can call `apply` before this view's first `layoutSubviews` pass
            // (e.g. immediately after `makeUIView`), and panes are parented into
            // `paneContentView` below - ensure it exists before that happens.
            ensurePaneContentViewInstalled()
            let sig = RenderSignature(state)
            guard sig != lastRenderSignature else { return }   // unchanged → skip re-layout
            let reason = renderChangeReason(old: lastRenderSignature, new: sig, state: state)
            lastRenderSignature = sig
            DebugLog.shared.log(.render, "render:panes reason=\(reason) active=\(state.activeWindow.map { "@\($0.raw)" } ?? "nil") windows=\(state.windows.count) panes=\(state.activeWindow.flatMap { state.window($0) }?.visibleLayout?.panes.count ?? -1)")
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
                coordinator?.modeTracker.forget(id)
                view.removeFromSuperview(); unregister(id); panes[id] = nil
            }

            // Create/position each pane; border the active one.
            // Track whether this apply CREATED any pane (window-switch/reattach): if so, we
            // re-query tmux `#{alternate_on}` after the loop so a re-created pane's alt-state
            // is re-seeded authoritatively (Bug 2). `forget()` above wiped it, and the fresh
            // view's live flag is unreliable (tmux never replays `?1049h`).
            var createdAnyPane = false
            for rect in rects {
                let existed = panes[rect.pane] != nil
                if !existed { createdAnyPane = true }
                let view = panes[rect.pane] ?? {
                    DebugLog.shared.log(.tmux, "pane \(rect.pane) CREATE TerminalView (reattach makes a fresh view)")
                    let t = PaneTerminalView(frame: .zero)
                    t.terminalDelegate = coordinator
                    // Our keybar IS this pane's input accessory view (a real UIInputView
                    // audio-feedback context, so `playInputClick()` fires). iOS shows the
                    // accessory of whichever pane is first responder.
                    t.inputAccessoryView = coordinator?.makeKeybarAccessory()
                    // Apply configured font so rendered pane matches the pinch baseline.
                    if let s = coordinator?.settings {
                        t.font = TerminalFontProvider.shared.font(for: s.fontFace, size: CGFloat(s.fontSize))
                        // Give the pane a scrollback buffer so the user can scroll
                        // back through session output — the raw-SSH path already does
                        // this (TerminalScreen.swift); tmux panes were missing it, so
                        // SwiftTerm's tiny default left nothing to scroll to. (Pre-attach
                        // history is separate: control mode doesn't replay it — that
                        // needs tmux copy-mode/capture-pane, a future capability.)
                        t.getTerminal().options.scrollback = s.scrollbackLines
                    }
                    // Event-driven InteractionMode: `pane` (this pane's PaneID) is
                    // captured directly by the closure — no reverse `paneID(for:)`
                    // lookup needed, since this view is created for exactly this pane.
                    let pane = rect.pane
                    t.onModeRelevantChange = { [weak coordinator] event, term in
                        let src: AltSource
                        switch event {
                        case .bufferChanged: src = .liveTransition
                        case .mouseChanged: src = .keepTracked
                        }
                        coordinator?.modeTracker.recompute(for: pane, terminal: term, altSource: src)
                    }
                    paneContentView.addSubview(t); panes[rect.pane] = t; register(rect.pane, t)
                    coordinator?.installHalo(on: t, pane: pane)
                    // Prime once at mount so a pane reattaching into a running
                    // alt-screen app (vim/Claude) is correct from frame one.
                    coordinator?.modeTracker.recompute(for: pane, terminal: t.getTerminal(), altSource: .keepTracked)
                    // If tmux's alternate_on query reply for this pane already arrived
                    // (raced pane creation), apply it now: the live recompute above ran
                    // before this pane had any output, so it can't yet know the pane is
                    // mid-alt-screen; the override closes that gap until the emulator's
                    // own flag is observed (see PaneModeTracker.setAltScreenOverride).
                    if let isAlt = coordinator?.vm.takeAltScreenOverride(for: pane) {
                        coordinator?.modeTracker.setAltScreenOverride(for: pane, isAlt: isAlt, terminal: t.getTerminal())
                    }
                    // Sync our alt-screen pan to this pane's CURRENT mode. The prime /
                    // override above fire `onChange` only on a mode CHANGE (deduped); a
                    // pane that resolves straight to `.appOwnsInput` is covered, but this
                    // guarantees the pan matches the mode regardless of dedup outcome.
                    if let coordinator {
                        coordinator.setAltScreenPan(
                            for: t, enabled: coordinator.modeTracker.mode(for: pane) == .appOwnsInput)
                    }
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
                        DebugLog.shared.log(.tmux, "pane \(rect.pane) ACTIVE existed=\(existed) inWindow=\(view.window != nil) becomeFirstResponder→\(ok) isFR=\(view.isFirstResponder)")
                    } else {
                        DebugLog.shared.log(.tmux, "pane \(rect.pane) ACTIVE already firstResponder")
                    }
                } else {
                    view.layer.borderColor = inactiveBorderColor.cgColor
                    view.layer.borderWidth = singlePane ? 0 : 0.5
                }
            }

            // A pane was (re-)created this apply (window-switch/reattach). Re-query tmux's
            // authoritative `#{alternate_on}` so the fresh pane's tracked alt-state is
            // re-seeded via onAltScreenReconcile -> setAltScreenOverride, instead of falling
            // through to the unreliable live emulator flag (Bug 2: a re-created Claude pane
            // misclassified as .mouseReporting -> drag became a stuck selection).
            if createdAnyPane {
                coordinator?.vm.requeryAltScreenState()
            }

            // Finger-drag commit handoff: after rebuilding the new window's panes, if the
            // active window actually changed, complete any pending switch (reset the content
            // transform now that live panes fill it, drop the covering snapshot). Runs after
            // panes are positioned so the handoff lands on the final layout. The coordinator
            // is nonisolated; wrap in `assumeIsolated` to match the file's convention for
            // @MainActor calls from this UIView method (apply always runs on the main thread
            // via SwiftUI `updateUIView`).
            if state.activeWindow != previousActiveWindow, let newActive = state.activeWindow {
                MainActor.assumeIsolated {
                    coordinator?.completePendingSwitchIfNeeded(newActive: newActive)
                }
            }
            previousActiveWindow = state.activeWindow
        }

        /// Why a render fired — for the `.render` diagnostic. Compares the previous signature-
        /// bearing state to the new one via cheap field checks. Best-effort labeling.
        private func renderChangeReason(old: RenderSignature?, new: RenderSignature, state: TmuxSessionState) -> String {
            old == nil ? "initial" : "changed"
        }
    }
}
