// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import SwiftTerm
import SemicolynSSHCoreFFI
import SemicolynKit

/// Wraps SwiftTerm's UIKit `TerminalView` for SwiftUI. Output bytes from the
/// Rust PTY (via `TerminalShellOutput.onBytes`) are fed into the terminal;
/// user input goes out through the `send` closure (which routes to the active
/// transport: ET, Mosh, or the raw-PTY write).
struct TerminalScreen: UIViewRepresentable {
    /// Called with raw keystroke/paste bytes. Routes through the VM's transport-aware
    /// `sendTerminalInput` (ET stream, Mosh session, or the raw-PTY channel).
    let send: ([UInt8]) -> Void
    let output: TerminalShellOutput
    /// The live session is retained here for resize notifications only.
    let session: ShellSession?
    /// Optional explicit resize sink (debounced cols/rows). When set, it OWNS
    /// resize delivery and `session?.resize` is NOT called, used by the Mosh path
    /// (which has no `ShellSession`; it drives `MoshSession.resizeCols:rows:` via
    /// `vm.setMoshClientSize`). When nil, resize falls back to `session?.resize`
    /// (the raw-SSH path). Mirrors the tmux branch's `onTmuxResize` convention.
    var onResize: ((Int, Int) -> Void)? = nil
    /// Terminal rendering preferences (font, cursor, scrollback). Defaults from
    /// `AppStores.shared.terminalSettings.settings` at the call site.
    var settings: TerminalSettings = TerminalSettings()
    /// Active theme (used for bell halo color).
    var theme: Theme = Theme.neonMidnight
    /// Whether OSC 52 clipboard writes are allowed for this session (resolved at connect time).
    var osc52Allowed: Bool = true
    /// Called with the sanitized OSC 0/2 title; routes to `vm.terminalTitle`.
    var onTitle: ((String) -> Void)? = nil
    /// Called when the user taps an ssh:// link; routes to the confirm-connect sheet.
    var onSSHLink: ((URL) -> Void)? = nil
    /// The connection view model, passed to the inputAccessory-hosted keybar/predictor.
    var vm: ConnectionViewModel
    /// Keybar customization store, passed to the inputAccessory-hosted keybar.
    var keybarSettings: KeybarSettingsStore = AppStores.shared.keybarSettings
    /// Whether a hardware keyboard is connected (drives the keybar's compact/hidden mode).
    var hardwareKeyboardConnected: Bool = false
    /// `vm.keyboardFocusRequestToken`, passed BY VALUE: SwiftUI only re-runs `updateUIView`
    /// when this representable's inputs change, and `vm` is the same reference across a token
    /// bump, so reading the token through `vm` alone never fired on sheet dismiss (device
    /// build 173: the request ran only when the app later backgrounded).
    var keyboardFocusRequestToken: Int = 0

    func makeCoordinator() -> Coordinator {
        let c = Coordinator(send: send, session: session, settings: settings, theme: theme, osc52Allowed: osc52Allowed, onTitle: onTitle)
        c.onSSHLink = onSSHLink
        c.onResize = onResize
        c.vm = vm
        // Only a focus request made AFTER this terminal mounted should act (a remount
        // with a stale token must not re-present on its first pass).
        c.lastFocusRequestToken = keyboardFocusRequestToken
        // Build + retain the keybar audio-feedback accessory for this terminal.
        c.keybarAccessory = KeybarInputAccessory(vm: vm, keybarSettings: keybarSettings,
                                                 theme: theme,
                                                 hardwareKeyboardConnected: hardwareKeyboardConnected)
        return c
    }

    func makeUIView(context: Context) -> RawTerminalContainer {
        let terminal = PaneTerminalView(frame: .zero)
        // Raw single-terminal path: `RawTerminalContainer` owns the child's frame height
        // (window-space `rawTerminalChildHeight`, PR #122), so the child must NOT self-inset.
        terminal.terminalDelegate = context.coordinator
        // Event-driven InteractionMode: recompute on every alt-screen / mouse-mode
        // transition (single-pane mount → nil key), then refresh the dot immediately.
        terminal.onModeRelevantChange = { [weak coordinator = context.coordinator] event, term in
            coordinator?.modeTracker.recompute(terminal: term, altSource: .rawLive)
            // Connecting overlay: tmux turning mouse reporting on is the "attached" signal
            // (the VM ignores it unless the overlay is up). Delivered on the main thread
            // from a nonisolated SwiftTerm hook; hop onto the main actor for the VM.
            if case .mouseChanged = event {
                let on = term.mouseMode != .off
                let vm = coordinator?.vm
                MainActor.assumeIsolated {
                    vm?.noteTerminalMouseMode(on: on)
                }
            }
        }
        // Mode now only drives the mouse dot and the gesture context; recognizers are
        // never toggled. (Replaces the init-time dot-only closure.)
        context.coordinator.modeTracker.onChange = { [weak coordinator = context.coordinator] _, mode in
            coordinator?.mouseDot.isHidden = !(mode == .appOwnsInput || mode == .mouseReporting)
        }
        // Prime once at mount so a terminal that starts on the alt-screen (reattach
        // into a running vim/Claude) is correct from frame one.
        context.coordinator.modeTracker.recompute(terminal: terminal.getTerminal(), altSource: .rawLive)
        // Our keybar IS the terminal's input accessory view now (a real UIInputView
        // audio-feedback context, so `playInputClick()` fires). This replaces both
        // SwiftTerm's built-in bar and the old `.safeAreaInset` keybar mount.
        terminal.inputAccessoryView = context.coordinator.keybarAccessory

        // Apply terminal rendering preferences from settings.
        let s = context.coordinator.settings
        terminal.font = TerminalFontProvider.shared.font(for: s.fontFace, size: CGFloat(s.fontSize))
        terminal.getTerminal().options.scrollback = s.scrollbackLines
        // Apply the theme's terminal palette (bg/fg/cursor/selection + 16 ANSI).
        applyPalette(theme.terminalPalette(), to: terminal)
        applyCursor(to: terminal, style: s.cursorStyle, blink: s.cursorBlink)

        // Install bell halo overlay (full-frame, non-interactive).
        let halo = context.coordinator.halo
        halo.frame = terminal.bounds
        halo.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        terminal.addSubview(halo)

        // Install mouse-active indicator dot (top-left corner, fixed 4pt).
        terminal.addSubview(context.coordinator.mouseDot)

        // Attach pinch-to-zoom gesture. Scale is applied live on .changed and
        // committed to coordinator.baseSize on .ended; not persisted to the host.
        let pinch = UIPinchGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePinch(_:))
        )
        terminal.addGestureRecognizer(pinch)

        // If `attachPlainTmux` launched a plain-tmux session for this connection
        // (per-host/default `resolveUseTmux`), build the gesture controller now;
        // `screen` is only the mount signal, the controller only needs the
        // transport-aware send closure. No-op (and `vm.plainTmux` stays nil) when
        // tmux is off or no plain-tmux launch is pending yet, so the callbacks
        // below fall through to the unchanged raw no-ops. Stash the mounted view
        // so a transport that launches plain tmux AFTER this mount (Mosh/ET,
        // in-band on `onFirstFrame`) can install the controller later via
        // `installPlainTmuxControllerIfMounted()` (SSH installs right here since
        // its pending name is already set).
        vm.setMountedTerminalView(terminal)
        vm.installPlainTmuxControllerIfNeeded(screen: terminal)

        // Single gesture engine (spec 2026-10-04): fixed configuration, no runtime flips.
        // Native scrolling and SwiftTerm's mouse forwarding are off for good; the engine
        // scrolls (SwiftTerm scrollUp/Down or wheel/arrow bytes) and forwards clicks itself.
        terminal.isScrollEnabled = false
        terminal.allowMouseReporting = false
        terminal.delaysContentTouches = false
        let coordinator = context.coordinator
        let executor = GestureIntentExecutor(terminal: terminal, hooks: .init(
            plainTmux: { [weak coordinator] in coordinator?.vm?.plainTmux },
            mode: { [weak coordinator] in coordinator?.modeTracker.mode ?? .localScroll },
            altScrollDecision: { [weak coordinator] in coordinator?.currentAltScrollDecision()
                ?? altScrollDecision(mode: AppStores.shared.terminalSettings.settings.altScrollMode,
                                     paneCommand: nil, windowTitle: nil, registry: .bundledDefault) },
            sendBytes: { [weak coordinator] bytes in coordinator?.send(bytes) },
            placeCursor: { [weak coordinator, weak terminal] col, row in
                guard let terminal else { return }
                coordinator?.placeCursor(toCol: col, toRow: row, in: terminal)
            },
            restoreKeyboard: { [weak coordinator, weak terminal] in
                guard let coordinator, let terminal else { return }
                let action = keyboardRestoreAction(isFirstResponder: terminal.isFirstResponder,
                                                   keyboardVisible: coordinator.keybarAccessory?.window != nil)
                coordinator.apply(action, to: terminal, reason: "tap")
            }))
        let recognizer = TerminalTouchRecognizer(
            makeContext: { [weak coordinator, weak terminal, weak executor] in
                guard let coordinator, let terminal else { return nil }
                return coordinator.gestureContext(for: terminal, selection: executor?.selection)
            },
            onIntents: { [weak executor] intents, from, to, reason in
                if !intents.isEmpty || from != to {
                    DebugLog.shared.log(.gesture, "gesture:intent \(intents) state=\(from)->\(to) reason=\(reason)")
                }
                // A drag that starts scrolling logs its scroll route once, at its first emit.
                if from != to, to == "scrolling" { executor?.logNextScrollRoute = true }
                executor?.perform(intents)
            })
        terminal.addGestureRecognizer(recognizer)
        coordinator.executor = executor
        coordinator.touchRecognizer = recognizer
        MainActor.assumeIsolated {
            DebugLog.shared.log(.seed, "scroll:init isScrollEnabled=\(terminal.isScrollEnabled) nativePan=\(terminal.panGestureRecognizer.isEnabled) contentSize=\(terminal.contentSize) offset=\(terminal.contentOffset)")
        }

        // Render PTY output as it arrives (already hopped to main in the bridge).
        output.onBytes = { [weak terminal] bytes in
            terminal?.feed(byteArray: bytes[...])
        }
        // Wrap the terminal in a plain-UIView container so IT (not the scroll view) is the
        // SwiftUI representable leaf. The container owns the child's frame from the correct
        // coordinate space; see RawTerminalContainer + the 2026-08-08 design spec. All the
        // wiring above stays attached to `terminal` (the child); only the returned leaf changes.
        let container = RawTerminalContainer(terminal: terminal)
        container.coordinator = context.coordinator
        return container
    }

    func updateUIView(_ uiView: RawTerminalContainer, context: Context) {
        let terminal = uiView.terminal
        // Claim keyboard focus ONCE when the view first lands in a window (so the
        // on-screen keyboard + keybar accessory appear). We don't re-claim on later
        // passes; a user who dismisses the keyboard is not fought here. Re-showing it
        // after dismissal is a tap: the gesture engine's `restoreKeyboard` intent.
        if !context.coordinator.didInitialFocus, terminal.window != nil {
            context.coordinator.didInitialFocus = true
            terminal.becomeFirstResponder()
        }
        // Re-present the keyboard when the VM requests focus (the keybar's Settings sheet
        // closing). Presenting that sheet from the keybar (an inputAccessoryView) hides the
        // keyboard WITHOUT resigning first responder, so a plain become is a no-op; the
        // decision forces a reload in that case (same fix as the removed -CC pane container,
        // PR #128, which the raw/plain-tmux screen never got: device build 172). Act only on a NEW
        // token so repeated SwiftUI passes never thrash.
        if keyboardFocusRequestToken != context.coordinator.lastFocusRequestToken {
            context.coordinator.lastFocusRequestToken = keyboardFocusRequestToken
            let action = keyboardRestoreAction(isFirstResponder: terminal.isFirstResponder,
                                               keyboardVisible: false)
            context.coordinator.apply(action, to: terminal, reason: "focusRequest")
        }
        // Refresh halo color when theme changes.
        context.coordinator.halo.configure(color: UIColor(Color(theme.bell.edge)))
        // Recolor the live terminal when the theme changes.
        applyPalette(theme.terminalPalette(), to: terminal)
        // Re-apply the font live when the user changes face/size in the settings
        // picker. Compare against the last SETTINGS-applied values (not the pinch
        // baseSize) so an in-progress pinch isn't clobbered on every SwiftUI pass;
        // a deliberate settings change resets the pinch baseline to the new size.
        let coord = context.coordinator
        if settings.fontFace != coord.lastAppliedFace || settings.fontSize != coord.lastAppliedFontSize {
            terminal.font = TerminalFontProvider.shared.font(for: settings.fontFace, size: CGFloat(settings.fontSize))
            coord.lastAppliedFace = settings.fontFace
            coord.lastAppliedFontSize = settings.fontSize
            coord.baseSize = settings.fontSize
        }
        // Update mouse-active dot visibility and selection gesture state.
        context.coordinator.updateMouseDot(from: terminal)
    }

    /// Tear down the gesture engine's display-link timer (it retains the recognizer) and
    /// the executor's edit-menu interaction and loupe.
    static func dismantleUIView(_ uiView: RawTerminalContainer, coordinator: Coordinator) {
        coordinator.touchRecognizer?.stopTimers()
        coordinator.executor?.detach()
    }

    /// Bridges SwiftTerm's delegate callbacks to the SSH session.
    final class Coordinator: NSObject, TerminalViewDelegate {
        private let onSend: ([UInt8]) -> Void
        private let session: ShellSession?
        let settings: TerminalSettings
        /// The keybar audio-feedback accessory, retained for this terminal's lifetime
        /// and assigned as the TerminalView's `inputAccessoryView`.
        var keybarAccessory: KeybarInputAccessory?
        /// Bell halo overlay installed into the TerminalView in makeUIView.
        let halo: BellHaloView
        private var bellMachine: BellStateMachine = BellStateMachine()
        /// Whether OSC 52 clipboard writes are permitted for this session.
        private let osc52Allowed: Bool
        /// Called with sanitized OSC 0/2 title strings.
        private let onTitle: ((String) -> Void)?
        /// Called when the user taps an ssh:// link; set by the connect view to prefill the connect form.
        var onSSHLink: ((URL) -> Void)?
        /// Explicit resize sink (set by `makeCoordinator`). When non-nil it owns
        /// resize delivery; when nil, `sizeChanged` falls back to `session?.resize`.
        var onResize: ((Int, Int) -> Void)?
        /// Debounces rapid resize events (rotation / keyboard show-hide) into a
        /// single remote window-change once the grid is stable for ~100ms.
        private var resizeDebounce: ResizeDebounce = ResizeDebounce()
        /// Mouse-active indicator dot (4pt, accent primary @ 40% opacity).
        /// Installed as a subview of the TerminalView in makeUIView.
        let mouseDot: UIView
        /// Long-press gesture recognizer used for text selection. Suspended while
        /// the terminal's mouse mode is active so mouse events reach the app.
        var selectionLongPress: UILongPressGestureRecognizer?
        /// Baseline font size for pinch-zoom; updated when a pinch gesture ends.
        /// Persists for the window's lifetime only (not stored to the host, v1.5+).
        var baseSize: Double
        /// Last font face/size applied FROM SETTINGS (not from a pinch). Used by
        /// `updateUIView` to detect a settings change (picker) and re-apply live,
        /// without clobbering an in-progress pinch on every SwiftUI pass.
        var lastAppliedFace: TerminalFont
        var lastAppliedFontSize: Double
        /// True once we've claimed keyboard focus the first time (on the first
        /// `updateUIView` after the view is in a window, so `becomeFirstResponder` can
        /// succeed). We don't re-claim on later passes (a user who dismisses the
        /// keyboard isn't fought); a tap re-shows it instead, through the gesture
        /// engine's `restoreKeyboard` intent.
        var didInitialFocus = false
        /// Last `vm.keyboardFocusRequestToken` acted on, so `updateUIView` can tell a NEW
        /// focus request apart from a repeated SwiftUI pass.
        var lastFocusRequestToken = 0
        /// The single gesture engine's executor and recognizer (spec 2026-10-04).
        var executor: GestureIntentExecutor?
        var touchRecognizer: TerminalTouchRecognizer?
        /// Tracks this pane's `InteractionMode`, recomputed from `PaneTerminalView`'s
        /// `bufferActivated`/`mouseModeChanged` overrides (event-driven, replaces the
        /// old render-time poll in `updateMouseDot`).
        let modeTracker = PaneModeTracker()
        /// The connection view model, weakly referenced so the coordinator doesn't
        /// extend its lifetime. Used only to source the password-line flag for the
        /// diagnostic keystroke-content gate in `send`.
        weak var vm: ConnectionViewModel?

        init(send: @escaping ([UInt8]) -> Void, session: ShellSession?, settings: TerminalSettings, theme: Theme,
             osc52Allowed: Bool = true, onTitle: ((String) -> Void)? = nil) {
            self.onSend = send
            self.session = session
            self.settings = settings
            self.baseSize = settings.fontSize
            self.lastAppliedFace = settings.fontFace
            self.lastAppliedFontSize = settings.fontSize
            self.halo = BellHaloView(frame: .zero)
            self.osc52Allowed = osc52Allowed
            self.onTitle = onTitle
            let dot = UIView(frame: CGRect(x: 8, y: 8, width: 4, height: 4))
            dot.layer.cornerRadius = 2
            dot.backgroundColor = UIColor(Color(theme.accent.primary.alpha(0.40)))
            dot.isUserInteractionEnabled = false
            dot.isHidden = true
            self.mouseDot = dot
            super.init()
            halo.configure(color: UIColor(Color(theme.bell.edge)))
            // Refresh the dot immediately on a mode transition, rather than waiting
            // for the next SwiftUI `updateUIView` pass. `makeUIView` replaces this
            // closure with an equivalent dot-only one.
            modeTracker.onChange = { [weak self] _, mode in
                self?.mouseDot.isHidden = !(mode == .appOwnsInput || mode == .mouseReporting)
            }
        }

        /// Handles pinch-to-zoom on the TerminalView.
        ///
        /// On `.changed`: applies `clampFont(baseSize * scale)` so the font tracks
        /// the live pinch ratio; scale is reset to 1 each frame so deltas compound
        /// correctly. On `.ended`: commits the final size back into `baseSize` and
        /// resets `recognizer.scale` to 1.
        ///
        /// - Assumption: `TerminalView.font` is a settable `UIFont` property (public
        ///   in SwiftTerm 1.x). Setting it replaces the terminal's monospace font
        ///   immediately. Cannot be verified on Linux; macOS CI is the correctness gate.
        @objc func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            guard let terminal = recognizer.view as? TerminalView else { return }
            switch recognizer.state {
            case .changed:
                let newSize = TerminalSettings.clampFont(baseSize * Double(recognizer.scale))
                // UIKit delivers gesture callbacks on the main thread; this @objc
                // selector is nonisolated, so hop onto the main actor to call the
                // @MainActor font provider.
                terminal.font = MainActor.assumeIsolated {
                    TerminalFontProvider.shared.font(for: settings.fontFace, size: CGFloat(newSize))
                }
                recognizer.scale = 1
                baseSize = newSize
            case .ended:
                // baseSize is up-to-date from the .changed accumulation; snap it to a
                // whole pt on release (font sizes are always integers, the live scale
                // above is smooth/fractional, this commits an integer).
                baseSize = TerminalSettings.roundedFont(baseSize)
                recognizer.scale = 1
                // Re-apply the rounded font so the visible size matches the persisted
                // integer (the last `.changed` left the terminal at the fractional size).
                terminal.font = MainActor.assumeIsolated {
                    TerminalFontProvider.shared.font(for: settings.fontFace, size: CGFloat(baseSize))
                }
                // Persist the zoomed size so it survives reconnect (and updates the
                // Settings font-size slider). The store is @MainActor; this @objc
                // callback is delivered on the main thread but is a nonisolated
                // context, so assume isolation. Guard so a no-op pinch doesn't churn
                // the persisted store.
                MainActor.assumeIsolated {
                    DebugLog.shared.log(.lifecycle, "user-action: zoom pinch → font=\(baseSize)")
                    let store = AppStores.shared.terminalSettings
                    if store.settings.fontSize != baseSize {
                        store.settings.fontSize = baseSize
                    }
                }
            default:
                break
            }
        }

        /// Carry out a `KeyboardRestoreAction` on `terminal` and log the decision. Used by
        /// the focus-request path and the gesture engine's `restoreKeyboard` hook (a tap
        /// restores the keyboard when the terminal lost focus or the keyboard is hidden,
        /// device build 172).
        func apply(_ action: KeyboardRestoreAction, to terminal: TerminalView, reason: String) {
            switch action {
            case .none:
                return
            case .becomeFirstResponder:
                terminal.becomeFirstResponder()
            case .reloadInputViews:
                terminal.reloadInputViews()
            }
            // UIKit callbacks arrive on the main thread but some callers are nonisolated
            // contexts; hop onto the main actor for the @MainActor logger.
            MainActor.assumeIsolated {
                DebugLog.shared.log(.input, "key:restore reason=\(reason) action=\(action) isFirstResponder=\(terminal.isFirstResponder)")
            }
        }

        // Keystrokes / pasted bytes from the user → remote (tmux or raw PTY).
        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            // Diagnostic (build 28, key-repeat investigation): classify + gate-log each
            // byte batch SwiftTerm emits. Holding a soft key that auto-repeats should
            // produce repeated send() calls; a single call while held means the OS is
            // not delivering repeat to SwiftTerm. Zero cost when diagnostics is disabled.
            // (Delegate callback is a nonisolated context; hop to the main actor.)
            MainActor.assumeIsolated {
                let logContent = UserDefaults.standard.bool(forKey: RemoteLogConfig.keystrokeContentKey)
                let isBackspace = data.count == 1 && (data.first == 0x7f || data.first == 0x08)
                let event = isBackspace ? "deleteBackward" : "insertText"
                // Best-effort content as UTF-8 for the gate; password-line flag sourced
                // from the VM's passwordDetector when the coordinator's weak ref is alive.
                let content = String(decoding: Array(data), as: UTF8.self)
                let isPwd = vm?.currentLineIsPassword() ?? false
                DebugLog.shared.log(.input, "key:\(keystrokeLogDecision(event: event, content: content, logContent: logContent, isPasswordLine: isPwd))")
            }
            onSend(Array(data))
        }

        /// Place the terminal cursor at (toCol,toRow) by emitting arrow keys from the
        /// current cursor cell (single-tap cursor placement, reuses the pure encoders).
        func placeCursor(toCol: Int, toRow: Int, in view: TerminalView) {
            let term = view.getTerminal()
            let cur = term.getCursorLocation()   // .x = col, .y = row (see SwiftTermEchoOracle)
            let appCursor = term.applicationCursor
            let runs = cursorTapArrows(fromCol: cur.x, fromRow: cur.y, toCol: toCol, toRow: toRow)
            for run in runs {
                let bytes = encodeArrowRun(run, applicationCursorKeys: appCursor)  // Kit encoder
                if !bytes.isEmpty { onSend(bytes) }
            }
        }

        /// Send raw bytes to the remote via the same path as keystrokes/paste
        /// (`onSend`). Used by the gesture engine's wheel / arrow / click byte streams.
        func send(_ bytes: [UInt8]) {
            onSend(bytes)
        }

        /// The alt-screen scroll decision for this terminal (raw / plain-tmux single pane: no
        /// tmux pane command; the window title feeds the registry).
        @MainActor
        func currentAltScrollDecision() -> AltScrollDecision {
            altScrollDecision(mode: AppStores.shared.terminalSettings.settings.altScrollMode,
                              paneCommand: nil, windowTitle: vm?.terminalTitle, registry: .bundledDefault)
        }

        /// Snapshot everything the gesture engine needs at touch-down.
        @MainActor
        func gestureContext(for terminal: TerminalView, selection: GestureSelection?) -> GestureContext {
            let term = terminal.getTerminal()
            let cols = max(term.cols, 1), rows = max(term.rows, 1)
            // True cell height: caretFrame is exactly one cell tall; bounds/rows overestimates.
            // NOT its width: SwiftTerm widens the caret to cellW * columnWidth on a wide (CJK)
            // cursor cell. Cell width = SwiftTerm's own computeFontDimensions width: the "W"
            // advance of the terminal font, snapped to the pixel grid (UIScreen.main.scale,
            // as SwiftTerm's iOS backingScaleFactor). Falls back to bounds/cols.
            let caret = terminal.caretFrame
            let scale = UIScreen.main.scale
            let advance = ("W" as NSString).size(withAttributes: [.font: terminal.font]).width
            let cellW = advance > 0 ? max(1, (advance * scale).rounded() / scale)
                                    : terminal.bounds.width / CGFloat(cols)
            let cellH = caret.height > 0 ? caret.height : terminal.bounds.height / CGFloat(rows)
            let mode = modeTracker.mode
            let keys = currentAltScrollDecision().keys
            let gain = (mode == .localScroll || keys == .wheel) ? 1.0 : AltScreenScroll.scrollGain
            return GestureContext(
                screen: GestureScreen(plainTmuxAttached: vm?.plainTmux != nil, mode: mode),
                mode: mode == .localScroll ? .local : .app,
                appMouseOn: term.mouseMode != .off,
                multiWindow: vm?.isMultiWindowTmux ?? false,
                selection: terminal.hasActiveSelection ? selection : nil,
                cellWidth: Double(cellW), cellHeight: Double(cellH),
                cols: cols, rows: rows, topRow: term.getTopVisibleRow(),
                contentOffsetY: Double(terminal.contentOffset.y),
                viewWidth: Double(terminal.bounds.width), scrollGain: gain)
        }

        // Grid resize (rotation, layout) → remote window-change, debounced.
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            // Sizing diagnostics (#4 keybar-height / #5 col-count, 2026-07-15): log the
            // terminal's geometry when SwiftTerm recomputes its grid, so a device trace
            // proves whether the view bounds already exclude the keybar (inputAccessoryView)
            // area. `si.bottom` nonzero = system-reserved space; `kbH` = the keybar height.
            // The delegate callback is a nonisolated context delivered on the main thread;
            // hop onto the main actor for the @MainActor UIKit reads + logger (same as `send`).
            MainActor.assumeIsolated {
                let si = source.safeAreaInsets
                let kbH = (source.inputAccessoryView as? KeybarInputAccessory)?.intrinsicContentSize.height ?? -1
                // `.tmux` (default-ON) not `.keybar` (off): grid/client-size is a
                // sizing concern that must capture on device without a manual toggle (#D).
                DebugLog.shared.log(.tmux,
                    "sizing:raw bounds=\(Int(source.bounds.width))x\(Int(source.bounds.height)) si=(t\(Int(si.top)),b\(Int(si.bottom))) kbH=\(String(format: "%.1f", kbH)) grid=\(newCols)x\(newRows)")
                // Full geometry for the RAW path (`geo:layout`). Raw reports SwiftTerm's OWN
                // self-measured grid and never subtracts the keybar (the terminal fills its
                // view, keybar floats over it). This line exposes exactly how raw places the
                // TerminalView so layout issues are visible, not inferred (device 2026-07-27).
                if DebugLog.shared.isEnabled(.geometry) {
                    let f = source.frame, co = source.contentOffset, cs = source.contentSize
                    let ci = source.contentInset, ai = source.adjustedContentInset
                    let t = source.getTerminal(), b = t.buffer
                    DebugLog.shared.log(.geometry,
                        "geo:raw frame=\(Int(f.minX)),\(Int(f.minY)),\(Int(f.width))x\(Int(f.height)) "
                        + "vbounds=\(Int(source.bounds.width))x\(Int(source.bounds.height)) si=(t\(Int(si.top)),b\(Int(si.bottom))) "
                        + "kbH=\(String(format: "%.1f", kbH)) grid=\(newCols)x\(newRows) rows\(t.rows) "
                        + "topRow\(t.getTopVisibleRow()) yDisp\(b.yDisp) scroll\(b.scrollTop)..\(b.scrollBottom) "
                        + "contentSize=\(Int(cs.width))x\(Int(cs.height)) offset=\(Int(co.x)),\(Int(co.y)) "
                        + "inset=(t\(Int(ci.top)),b\(Int(ci.bottom))) adjInset=(t\(Int(ai.top)),b\(Int(ai.bottom))) "
                        + "fr=\(source.isFirstResponder) clip=\(source.clipsToBounds) "
                        + "accFrame=\(source.inputAccessoryView.map { "\(Int($0.frame.width))x\(Int($0.frame.height))@y\(Int($0.frame.minY))" } ?? "none")")
                }
            }
            resizeDebounce.note(cols: newCols, rows: newRows, at: Date())
            let session = self.session
            let onResize = self.onResize
            DispatchQueue.main.asyncAfter(deadline: .now() + ResizeDebounce.quiet) { [weak self] in
                guard let self else { return }
                if let size = self.resizeDebounce.tick(at: Date()) {
                    if let onResize {
                        // Mosh path: the explicit sink owns delivery (→ vm.setMoshClientSize
                        // → MoshSession.resizeCols:rows: → shared winsize + SIGWINCH).
                        onResize(size.cols, size.rows)
                    } else {
                        // Raw-SSH path: resize the retained ShellSession directly.
                        Task { try? await session?.resize(cols: UInt32(size.cols), rows: UInt32(size.rows)) }
                    }
                }
            }
        }

        /// Update the mouse-dot *visual* from the event-driven `modeTracker` (no
        /// longer polls terminal state here, `PaneTerminalView`'s
        /// `bufferActivated`/`mouseModeChanged` overrides keep `modeTracker` current).
        /// `isScrollEnabled` / `allowMouseReporting` are fixed `false` at mount (the
        /// gesture engine owns scrolling and clicks); nothing here touches them.
        ///
        /// Called from `updateUIView` on each SwiftUI pass.
        func updateMouseDot(from terminalView: TerminalView) {
            let mode = modeTracker.mode
            mouseDot.isHidden = !(mode == .appOwnsInput || mode == .mouseReporting)
        }

        // Visual bell: pulse halo + optional haptic (throttled by BellStateMachine).
        func bell(source: TerminalView) {
            let haptic = bellMachine.ring(at: Date())
            halo.start(machine: bellMachine)
            if haptic {
                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            }
        }

        // Delegate methods.
        func scrolled(source: TerminalView, position: Double) {}
        func setTerminalTitle(source: TerminalView, title: String) {
            if let t = sanitizeTerminalTitle(title) { onTitle?(t) }
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
    }
}

/// Apply the caret style + blink to `terminal` by feeding the matching DECSCUSR
/// sequence (`ESC [ <n> SP q`).
///
/// This is the mechanism the Plan C spec calls for ("engine applies `\x1b[<n> q`
/// overrides") and uses only SwiftTerm's `feed`, already exercised for PTY
/// output, so it avoids any dependency on a native cursor-style property. The
/// `style` parameter is qualified to `SemicolynKit.CursorStyle` to disambiguate
/// from SwiftTerm's own `CursorStyle`.
private func applyCursor(to terminal: TerminalView, style: SemicolynKit.CursorStyle, blink: Bool) {
    let n: Int
    switch (style, blink) {
    case (.block, true):       n = 1
    case (.block, false):      n = 2
    case (.underline, true):   n = 3
    case (.underline, false):  n = 4
    case (.bar, true):         n = 5
    case (.bar, false):        n = 6
    }
    let seq = Array("\u{1b}[\(n) q".utf8)
    terminal.feed(byteArray: seq[...])
}
