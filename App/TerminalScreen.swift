// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import SwiftTerm
import SemicolynSSHCoreFFI
import SemicolynKit

/// Wraps SwiftTerm's UIKit `TerminalView` for SwiftUI. Output bytes from the
/// Rust PTY (via `TerminalShellOutput.onBytes`) are fed into the terminal;
/// user input goes out through the `send` closure (which routes to tmux
/// send-keys or raw-PTY write depending on the active session mode).
struct TerminalScreen: UIViewRepresentable {
    /// Called with raw keystroke/paste bytes. In tmux mode this routes through
    /// `TmuxRuntime.sendInput`; in raw-PTY mode it writes directly to the channel.
    let send: ([UInt8]) -> Void
    let output: TerminalShellOutput
    /// The live session is retained here for resize notifications only.
    let session: ShellSession?
    /// Optional explicit resize sink (debounced cols/rows). When set, it OWNS
    /// resize delivery and `session?.resize` is NOT called — used by the Mosh path
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
    /// The connection view model — passed to the inputAccessory-hosted keybar/predictor.
    var vm: ConnectionViewModel
    /// Keybar customization store — passed to the inputAccessory-hosted keybar.
    var keybarSettings: KeybarSettingsStore = AppStores.shared.keybarSettings
    /// Whether a hardware keyboard is connected (drives the keybar's compact/hidden mode).
    var hardwareKeyboardConnected: Bool = false

    func makeCoordinator() -> Coordinator {
        let c = Coordinator(send: send, session: session, settings: settings, theme: theme, osc52Allowed: osc52Allowed, onTitle: onTitle)
        c.onSSHLink = onSSHLink
        c.onResize = onResize
        c.vm = vm
        // Build + retain the keybar audio-feedback accessory for this terminal.
        c.keybarAccessory = KeybarInputAccessory(vm: vm, keybarSettings: keybarSettings,
                                                 theme: theme,
                                                 hardwareKeyboardConnected: hardwareKeyboardConnected)
        return c
    }

    func makeUIView(context: Context) -> TerminalView {
        let terminal = TerminalView(frame: .zero)
        terminal.terminalDelegate = context.coordinator
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

        // Our own `TerminalGestureController` (installed below) owns the pan/tap/
        // long-press touch map; SwiftTerm's built-in recognizers are disabled by its
        // sweep. `allowMouseReporting = false` here keeps SwiftTerm from forwarding
        // mouse events in a non-`mouse=a` pane; it's flipped back to `true` in a
        // `mouse=a` pane (see updateMouseDot) so a mouse app gets its events, and the
        // controller reads it via `mouseReportingActive` to yield in that case.
        terminal.allowMouseReporting = false

        // Restore the keyboard (and, with it, the keybar — which now rides as the
        // terminal's inputAccessoryView, PR #66) after it's been dismissed. A tap only
        // re-claims first responder when the terminal is NOT already first responder;
        // when the keyboard is up this recognizer no-ops and SwiftTerm's own tap
        // (cursor placement) works normally. `cancelsTouchesInView = false` so the tap
        // still reaches SwiftTerm.
        let restoreTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleRestoreTap(_:))
        )
        restoreTap.cancelsTouchesInView = false
        terminal.addGestureRecognizer(restoreTap)

        // Install our own gesture layer (replaces SwiftTerm's built-in tap/scrub/select).
        // Raw PTY: no tmux, so horizontal drag falls through to scroll and long-press
        // zoom is a no-op.
        let gestureController = TerminalGestureController(
            terminalView: terminal,
            callbacks: .init(
                isMultiWindowTmux: { false },
                onSwitchWindow: { _ in },
                onLongPressZoom: { },
                onPlaceCursor: { [weak coordinator = context.coordinator, weak terminal] col, row in
                    guard let terminal else { return }
                    coordinator?.placeCursor(toCol: col, toRow: row, in: terminal)
                },
                mouseReportingActive: { terminal.allowMouseReporting },
                hasSelection: { [weak terminal] in terminal?.selectionActive ?? false },
                clearSelection: { [weak terminal] in terminal?.selectNone() }
            )
        )
        context.coordinator.gestureController = gestureController
        // The controller's sweep disabled all pre-existing recognizers (SwiftTerm's +
        // ours-that-aren't). Re-enable the app's own pinch and keyboard-restore taps.
        pinch.isEnabled = true
        restoreTap.isEnabled = true
        MainActor.assumeIsolated {
            DebugLog.shared.log(.seed, "scroll:init isScrollEnabled=\(terminal.isScrollEnabled) nativePan=\(terminal.panGestureRecognizer.isEnabled) contentSize=\(terminal.contentSize) offset=\(terminal.contentOffset)")
        }

        // Render PTY output as it arrives (already hopped to main in the bridge).
        output.onBytes = { [weak terminal] bytes in
            terminal?.feed(byteArray: bytes[...])
        }
        return terminal
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {
        // Claim keyboard focus ONCE when the view first lands in a window (so the
        // on-screen keyboard + keybar accessory appear). We don't re-claim on later
        // passes — a user who dismisses the keyboard is not fought here. Re-showing it
        // after dismissal is the job of `handleRestoreTap` (tap the terminal).
        if !context.coordinator.didInitialFocus, uiView.window != nil {
            context.coordinator.didInitialFocus = true
            uiView.becomeFirstResponder()
        }
        // Refresh halo color when theme changes.
        context.coordinator.halo.configure(color: UIColor(Color(theme.bell.edge)))
        // Recolor the live terminal when the theme changes.
        applyPalette(theme.terminalPalette(), to: uiView)
        // Re-apply the font live when the user changes face/size in the settings
        // picker. Compare against the last SETTINGS-applied values (not the pinch
        // baseSize) so an in-progress pinch isn't clobbered on every SwiftUI pass;
        // a deliberate settings change resets the pinch baseline to the new size.
        let coord = context.coordinator
        if settings.fontFace != coord.lastAppliedFace || settings.fontSize != coord.lastAppliedFontSize {
            uiView.font = TerminalFontProvider.shared.font(for: settings.fontFace, size: CGFloat(settings.fontSize))
            coord.lastAppliedFace = settings.fontFace
            coord.lastAppliedFontSize = settings.fontSize
            coord.baseSize = settings.fontSize
        }
        // Update mouse-active dot visibility and selection gesture state.
        context.coordinator.updateMouseDot(from: uiView)
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
        /// Persists for the window's lifetime only (not stored to the host — v1.5+).
        var baseSize: Double
        /// Last font face/size applied FROM SETTINGS (not from a pinch). Used by
        /// `updateUIView` to detect a settings change (picker) and re-apply live,
        /// without clobbering an in-progress pinch on every SwiftUI pass.
        var lastAppliedFace: TerminalFont
        var lastAppliedFontSize: Double
        /// True once we've claimed keyboard focus the first time (on the first
        /// `updateUIView` after the view is in a window, so `becomeFirstResponder` can
        /// succeed). We don't re-claim on later passes (a user who dismisses the
        /// keyboard isn't fought); `handleRestoreTap` re-shows it on a tap instead.
        var didInitialFocus = false
        /// Retains the gesture layer for this terminal (replaces SwiftTerm's built-ins).
        var gestureController: TerminalGestureController?
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
                // baseSize is already up-to-date from the .changed accumulation above;
                // re-clamp and reset scale defensively.
                baseSize = TerminalSettings.clampFont(baseSize)
                recognizer.scale = 1
                // Persist the zoomed size so it survives reconnect (and updates the
                // Settings font-size slider). The store is @MainActor; this @objc
                // callback is delivered on the main thread but is a nonisolated
                // context, so assume isolation. Guard so a no-op pinch doesn't churn
                // the persisted store.
                MainActor.assumeIsolated {
                    DebugLog.shared.log(.gesture, "gesture:pinch fontSize=\(baseSize)")
                    let store = AppStores.shared.terminalSettings
                    if store.settings.fontSize != baseSize {
                        store.settings.fontSize = baseSize
                    }
                }
            default:
                break
            }
        }

        /// Re-show the keyboard (and the keybar accessory) after the user has dismissed
        /// it. Only acts when the terminal is NOT already first responder — when the
        /// keyboard is up, this no-ops and SwiftTerm's own tap (cursor placement) is
        /// unaffected (this recognizer has `cancelsTouchesInView = false`).
        @objc func handleRestoreTap(_ recognizer: UITapGestureRecognizer) {
            guard let terminal = recognizer.view as? TerminalView else { return }
            if !terminal.isFirstResponder {
                let ok = terminal.becomeFirstResponder()
                // @objc gesture callbacks are delivered on the main thread but are a
                // nonisolated context; hop onto the main actor for the @MainActor logger.
                MainActor.assumeIsolated { DebugLog.shared.log(.input, "key:firstResponder becomeFirstResponder=\(ok) isFirstResponder=\(terminal.isFirstResponder)") }
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
        /// current cursor cell (single-tap cursor placement — reuses the pure encoders).
        func placeCursor(toCol: Int, toRow: Int, in view: TerminalView) {
            let term = view.getTerminal()
            let cur = term.getCursorLocation()   // .x = col, .y = row (see SwiftTermEchoOracle)
            let runs = cursorTapArrows(fromCol: cur.x, fromRow: cur.y, toCol: toCol, toRow: toRow)
            for run in runs {
                let bytes = encodeArrowRun(run)
                if !bytes.isEmpty { onSend(bytes) }
            }
        }

        /// Encode one ArrowRun to its CSI escape bytes, repeated `count` times.
        private func encodeArrowRun(_ run: ArrowRun) -> [UInt8] {
            let tail: [UInt8]
            switch run.direction {
            case .up:    tail = [0x1b, 0x5b, 0x41]   // ESC [ A
            case .down:  tail = [0x1b, 0x5b, 0x42]   // ESC [ B
            case .right: tail = [0x1b, 0x5b, 0x43]   // ESC [ C
            case .left:  tail = [0x1b, 0x5b, 0x44]   // ESC [ D
            }
            return Array(repeating: tail, count: run.count).flatMap { $0 }
        }

        // Grid resize (rotation, layout) → remote window-change, debounced.
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
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

        /// Poll mouse mode from the terminal and update dot visibility / gesture state.
        ///
        /// Called from `updateUIView` on each SwiftUI pass. Forward a drag as a mouse
        /// event ONLY when the foreground app is on the ALTERNATE screen (vim/htop/less);
        /// a normal-screen app that merely enabled mouse mode must not capture the drag,
        /// or a swipe is sent as SGR mouse reports instead of scrolling locally. Mirrors
        /// the tmux path (`TmuxPaneContainer.updateMouseDots`); `isCurrentBufferAlternate`
        /// is the same public SwiftTerm API used by `SwiftTermEchoOracle`.
        func updateMouseDot(from terminalView: TerminalView) {
            let terminal = terminalView.getTerminal()
            let forwardMouse = terminal.mouseMode != .off && terminal.isCurrentBufferAlternate
            mouseDot.isHidden = !forwardMouse
            // Alt-screen mouse app → forward mouse events. Otherwise keep off so SwiftTerm's
            // pan scrolls and tap/long-press do reposition + selection (cursor-centric model).
            terminalView.allowMouseReporting = forwardMouse
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
/// overrides") and uses only SwiftTerm's `feed` — already exercised for PTY
/// output — so it avoids any dependency on a native cursor-style property. The
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
