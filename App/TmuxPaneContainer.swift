// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import SwiftTerm
import CoreText
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
                v.coordinator?.setSwitchPan(for: view, enabled: mode != .appOwnsInput)
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
        /// Device #2 (Build 2): while a window switch is settling, the keybar/keyboard show
        /// animation grows the container bounds through a burst of intermediate sizes
        /// (e.g. 80x35 -> 80x44 -> 80x33). Sending each to tmux resized the window multiple
        /// times, and a TRANSIENT wrong size landed on the active window -> content filled the
        /// wrong row count -> "bottom halfway up, rest blank". This deadline extends the
        /// resize debounce during the settle so only the FINAL settled size reaches tmux.
        private var resizeSettleUntil: Date?
        /// The extended debounce quiet window used while `resizeSettleUntil` is in the future -
        /// long enough to span the keyboard/keybar grow animation (feel-tuned; the animation is
        /// ~150-400ms). Outside the settle window the normal `ResizeDebounce.quiet` applies.
        private static let switchResizeQuiet: TimeInterval = 0.45
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
                        onDragCommit: { [weak self] delta in
                            self?.onSwitchWindow(delta)   // tmux select-window; tmux redraws (KISS)
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

        /// Enable/disable a pane's switch pan (mirrors `setAltScreenPan`). Called from the
        /// mode-transition handler so exactly one switch-owner is live per mode: `switchPan`
        /// in `.localScroll`/`.mouseReporting`, `altScreenPan` in `.appOwnsInput`.
        func setSwitchPan(for view: TerminalView, enabled: Bool) {
            MainActor.assumeIsolated {
                gestureControllers[ObjectIdentifier(view)]?.setSwitchPanEnabled(enabled)
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
        /// Arm the resize-settle window (device #2 Build 2): for the next `switchResizeQuiet`
        /// seconds, `noteClientSize` uses the longer debounce so a switch's keyboard/keybar grow
        /// animation coalesces to one final tmux resize instead of a burst of intermediate sizes.
        func armResizeSettle() {
            resizeSettleUntil = Date().addingTimeInterval(Self.switchResizeQuiet)
        }

        func noteClientSize(cols: Int, rows: Int) {
            let now = Date()
            resizeDebounce.note(cols: cols, rows: rows, at: now)
            // Device #2 (Build 2): during a switch-settle window use a LONGER quiet so the
            // keyboard/keybar grow animation's intermediate sizes (35 -> 44 -> 33) coalesce to
            // one emit of the final settled size, instead of resizing tmux mid-animation and
            // stranding the active window at a transient row count (the half-blank pane).
            let settling = (resizeSettleUntil.map { now < $0 }) ?? false
            let quiet = settling ? Self.switchResizeQuiet : ResizeDebounce.quiet
            DispatchQueue.main.asyncAfter(deadline: .now() + quiet) { [weak self] in
                guard let self else { return }
                if let size = self.resizeDebounce.tick(at: Date(), quiet: quiet) {
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

        /// Last-applied render signature. `apply(state:)` skips the (expensive) pane re-layout
        /// when the new state's signature matches — the SwiftUI `updateUIView` pass fires far
        /// more often than the rendered layout actually changes (the render storm).
        private var lastRenderSignature: RenderSignature?

        /// The pane layout applied by the last `apply` (device #2, 2026-07-20). `apply` sets
        /// pane frames, but it is gated by `RenderSignature` (no geometry dependency), so when
        /// the container bounds change WITHOUT a tmux-state change (the keybar/keyboard show
        /// animation growing bounds after a window switch) the panes are never re-framed and a
        /// newly-revealed pane stays sized to a stale, tiny bounds snapshot until a scroll
        /// provokes a tmux event. `relayoutExistingPaneFrames()` replays this layout on a pure
        /// geometry change so a revealed pane tracks the grow animation.
        private var lastAppliedLayout: PaneLayout?
        /// The bounds size at the last `layoutSubviews` relayout, to fire the geometry-only
        /// pane re-frame ONLY when bounds actually changed (avoids churn under the render storm).
        private var lastLaidOutBounds: CGSize = .zero

        /// The active window as of the last `apply` that reached the change-detect at the
        /// end of the method. Compared against `state.activeWindow` there to decide whether
        /// to arm the keybar-grow resize-settle debounce (see `armResizeSettle`).
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
            // Device #1 (2026-07-20): the keybar (inputAccessoryView) is NOT propagated into
            // our safeArea (si=(t0,b0) on device), so `bounds` includes the keybar+keyboard
            // band and the terminal rendered behind the bar. Subtract the keybar height so
            // every pane occupies only the visible area above the bar. kbH<=0 = keyboard down
            // (no accessory) -> full height.
            let kbH = firstResponderKeybarHeight()
            let usableH = visibleTerminalHeight(rawHeight: Double(bounds.height), keybarHeight: Double(kbH))
            let cell = resolvedCell()
            // Grid from the KEYBAR-ADJUSTED height (device #1), not raw bounds.height.
            guard let grid = terminalGrid(width: Double(bounds.width), height: usableH,
                                          cellWidth: cell.w, cellHeight: cell.h) else { return }
            // Sizing diagnostics (#4 keybar-height / #5 col-count, 2026-07-15). Log the
            // full geometry at the grid-computation boundary. `si` = safeAreaInsets; a nonzero
            // `.bottom` = system reserved space. `kbH` = the active pane's keybar accessory
            // height; `usableH` = bounds.height with the keybar subtracted (what the grid uses).
            // Logged under `.tmux` (default-ON) so the grid/client-size mismatch captures on a
            // device build without a manual toggle.
            let si = safeAreaInsets
            DebugLog.shared.log(.tmux,
                "sizing:tmux bounds=\(Int(bounds.width))x\(Int(bounds.height)) si=(t\(Int(si.top)),b\(Int(si.bottom))) cell=\(String(format: "%.1f", cell.w))x\(String(format: "%.1f", cell.h)) kbH=\(String(format: "%.1f", kbH)) usableH=\(Int(usableH)) grid=\(grid.cols)x\(grid.rows)")
            coordinator?.noteClientSize(cols: grid.cols, rows: grid.rows)

            // Device #2 (2026-07-20): re-frame existing panes when the container geometry
            // changed WITHOUT a tmux-state change (the keybar/keyboard show animation growing
            // bounds after a window switch). `apply` is gated by `RenderSignature` (no geometry
            // dependency), so a pane revealed mid-grow stays at its stale tiny frame until a
            // scroll provokes a tmux event. Fire only on an actual bounds-size change to avoid
            // churn under the -CC render storm.
            if bounds.size != lastLaidOutBounds {
                lastLaidOutBounds = bounds.size
                relayoutExistingPaneFrames(cell: cell)
            }
        }

        /// Re-apply `paneRects` to the panes ALREADY in `panes` (no create/destroy, no
        /// first-responder/border changes) so a revealed pane tracks a geometry-only bounds
        /// change. No-ops when no layout has been applied yet. Device #2.
        private func relayoutExistingPaneFrames(cell: (w: Double, h: Double)) {
            guard let layout = lastAppliedLayout else { return }
            for rect in paneRects(in: layout, cellWidth: cell.w, cellHeight: cell.h) {
                guard let view = panes[rect.pane] else { continue }
                view.frame = CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
            }
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
                    // DIAGNOSTIC (cell-width bug 2026-07-23): the .ttf says Hack/JetBrains Nerd
                    // Fonts advance 'W' at 7.8pt@13, but getOptimalFrameSize yields ~5.0/col ->
                    // we over-report cols to tmux -> text wraps/staircases. Log every candidate
                    // measurement for the LIVE pane font so we know which path gives the true
                    // advance on-device (getOptimalFrameSize vs UIFont "W".size vs a CTFont
                    // unicode-advance via cmap). Remove once the fix is chosen.
                    let f = pane.font
                    let uikitW = Double("W".size(withAttributes: [.font: f]).width)
                    var ctAdv = -1.0
                    let ct = f as CTFont
                    var uni: [UniChar] = Array("W".utf16)
                    var glyphs = [CGGlyph](repeating: 0, count: uni.count)
                    if CTFontGetGlyphsForCharacters(ct, &uni, &glyphs, uni.count) {
                        var adv = CGSize.zero
                        CTFontGetAdvancesForGlyphs(ct, .horizontal, &glyphs, &adv, 1)
                        ctAdv = Double(adv.width)
                    }
                    let scale = pane.window?.screen.scale ?? UIScreen.main.scale
                    DebugLog.shared.log(.render,
                        "cell-probe fontName=\(f.fontName) pt=\(f.pointSize) optimalW/col=\(String(format: "%.2f", w)) uikitWsize=\(String(format: "%.2f", uikitW)) ctUnicodeAdv=\(String(format: "%.2f", ctAdv)) lineHeight=\(String(format: "%.2f", Double(f.lineHeight))) screenScale=\(scale) cols=\(Int(cols))")
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
            let sig = RenderSignature(state)
            guard sig != lastRenderSignature else { return }   // unchanged → skip re-layout
            let reason = renderChangeReason(old: lastRenderSignature, new: sig, state: state)
            lastRenderSignature = sig
            DebugLog.shared.log(.render, "render:panes reason=\(reason) active=\(state.activeWindow.map { "@\($0.raw)" } ?? "nil") windows=\(state.windows.count) panes=\(state.activeWindow.flatMap { state.window($0) }?.visibleLayout?.panes.count ?? -1)")
            guard let win = state.activeWindow, let window = state.window(win),
                  let layout = window.visibleLayout else { return }
            lastAppliedLayout = layout   // device #2: so layoutSubviews can re-frame on a geometry-only change

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
                    addSubview(t); panes[rect.pane] = t; register(rect.pane, t)
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
                    // Sync our alt-screen + switch pans to this pane's CURRENT mode. The
                    // prime / override above fire `onChange` only on a mode CHANGE
                    // (deduped); a pane that resolves straight to `.appOwnsInput` is
                    // covered, but this guarantees the pans match the mode regardless of
                    // dedup outcome.
                    if let coordinator {
                        coordinator.setAltScreenPan(
                            for: t, enabled: coordinator.modeTracker.mode(for: pane) == .appOwnsInput)
                        coordinator.setSwitchPan(
                            for: t, enabled: coordinator.modeTracker.mode(for: pane) != .appOwnsInput)
                    }
                    return t
                }()
                view.frame = CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
                // Staircase/wrap diagnostic (`.sizing`, default-OFF). Compare, for THIS
                // pane, the three widths that must all agree or text re-wraps:
                //   frameW   — the pane's on-screen point width we just set
                //   stCols   — SwiftTerm's OWN buffer cols (frameW ÷ its cell); what it
                //              actually lays glyphs out at
                //   layoutW  — the pane width tmux put in %layout (the cols tmux formats
                //              output for) — from `rect` via the cell
                //   cell.w   — the cell we derived (5.0 on device)
                // If stCols ≪ layoutW (e.g. 50 vs 80) the pane view is narrower than tmux
                // thinks → tmux's 80-wide lines re-wrap in a ~50-wide SwiftTerm buffer =
                // the staircase. If they match but it still staircases, the wrap is glyph
                // advance vs cell (render), not buffer width.
                DebugLog.shared.log(.sizing, {
                    let term = view.getTerminal()
                    let layoutCols = cell.w > 0 ? Int((Double(rect.width) / cell.w).rounded()) : -1
                    return "sizing:pane @\(rect.pane.raw) frameW=\(Int(rect.width)) stCols=\(term.cols) stRows=\(term.rows) layoutCols≈\(layoutCols) cell.w=\(String(format: "%.2f", cell.w)) fontPt=\(String(format: "%.1f", Double(view.font.pointSize)))"
                }())
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

            if state.activeWindow != previousActiveWindow, state.activeWindow != nil {
                MainActor.assumeIsolated {
                    coordinator?.armResizeSettle()   // keybar-grow resize debounce on window change (KEEP)
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
