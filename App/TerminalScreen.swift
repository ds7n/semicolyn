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
        terminal.font = UIFont.monospacedSystemFont(ofSize: CGFloat(s.fontSize), weight: .regular)
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

        // Cursor placement uses SwiftTerm's OWN gestures, not a custom controller:
        // with `allowMouseReporting = false`, SwiftTerm turns a pan into cursor-key
        // commands (drag = scrub) and its native tap/double-tap/long-press give
        // reposition + word/line select + selection-extend. We flip it back to `true`
        // in a `mouse=a` pane (see updateMouseDot) so a mouse app gets its events. A
        // custom pan controller here just fought SwiftTerm's built-in pan (device:
        // scrub + selection-drag both broke).
        terminal.allowMouseReporting = false

        // Render PTY output as it arrives (already hopped to main in the bridge).
        output.onBytes = { [weak terminal] bytes in
            terminal?.feed(byteArray: bytes[...])
        }
        return terminal
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {
        // Claim keyboard focus ONCE so the on-screen keyboard appears on the raw/mosh
        // path (the tmux path does the equivalent per active pane). Done here, not in
        // makeUIView, because a view must be in a window for becomeFirstResponder to
        // take — the first updateUIView is the earliest that reliably holds. Claiming
        // only once means a user who later dismisses the keyboard is not fought.
        if !context.coordinator.didClaimFocus, uiView.window != nil {
            context.coordinator.didClaimFocus = true
            uiView.becomeFirstResponder()
        }
        // Refresh halo color when theme changes.
        context.coordinator.halo.configure(color: UIColor(Color(theme.bell.edge)))
        // Recolor the live terminal when the theme changes.
        applyPalette(theme.terminalPalette(), to: uiView)
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
        // TODO(phase4): wired when the connect-prefill / Esc-pill lands
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
        // TODO(phase4): wired when the connect-prefill / Esc-pill lands
        /// Long-press gesture recognizer used for text selection. Suspended while
        /// the terminal's mouse mode is active so mouse events reach the app.
        var selectionLongPress: UILongPressGestureRecognizer?
        /// Baseline font size for pinch-zoom; updated when a pinch gesture ends.
        /// Persists for the window's lifetime only (not stored to the host — v1.5+).
        var baseSize: Double
        /// True once we have claimed keyboard focus for this terminal. We claim it a
        /// single time (on the first `updateUIView` after the view is in a window, so
        /// `becomeFirstResponder` can actually succeed) and then never re-grab it, so
        /// a user who dismisses the keyboard is not fought on every SwiftUI pass.
        var didClaimFocus = false

        init(send: @escaping ([UInt8]) -> Void, session: ShellSession?, settings: TerminalSettings, theme: Theme,
             osc52Allowed: Bool = true, onTitle: ((String) -> Void)? = nil) {
            self.onSend = send
            self.session = session
            self.settings = settings
            self.baseSize = settings.fontSize
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
                terminal.font = UIFont.monospacedSystemFont(ofSize: CGFloat(newSize), weight: .regular)
                recognizer.scale = 1
                baseSize = newSize
            case .ended:
                // baseSize is already up-to-date from the .changed accumulation above;
                // re-clamp and reset scale defensively.
                baseSize = TerminalSettings.clampFont(baseSize)
                recognizer.scale = 1
            default:
                break
            }
        }

        // Keystrokes / pasted bytes from the user → remote (tmux or raw PTY).
        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            onSend(Array(data))
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
        /// Called from `updateUIView` on each SwiftUI pass. Best-effort: if SwiftTerm
        /// changes the `mouseMode` API this will need updating.
        ///
        /// - Assumption: `TerminalView.getTerminal().mouseMode` returns a value that
        ///   compares unequal to `.off` (or equivalent) when mouse reporting is active.
        ///   This is the best-known SwiftTerm 1.x public API; not verifiable on Linux.
        func updateMouseDot(from terminalView: TerminalView) {
            let mouseActive = terminalView.getTerminal().mouseMode != .off
            mouseDot.isHidden = !mouseActive
            // Mouse-reporting app → let SwiftTerm forward mouse events (allowMouseReporting
            // = true). Otherwise keep it false so SwiftTerm's pan is cursor-key scrub and
            // its tap/long-press do reposition + selection (cursor-centric model).
            terminalView.allowMouseReporting = mouseActive
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
