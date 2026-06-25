// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import SwiftTerm
import NeotildeSSHCoreFFI
import NeotildeKit

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
    /// Terminal rendering preferences (font, cursor, scrollback). Defaults from
    /// `AppStores.shared.terminalSettings.settings` at the call site.
    var settings: TerminalSettings = TerminalSettings()
    /// Active theme (used for bell halo color).
    var theme: Theme = Theme.default
    /// Whether OSC 52 clipboard writes are allowed for this session (resolved at connect time).
    var osc52Allowed: Bool = true
    /// Called with the sanitized OSC 0/2 title; routes to `vm.terminalTitle`.
    var onTitle: ((String) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(send: send, session: session, settings: settings, theme: theme, osc52Allowed: osc52Allowed, onTitle: onTitle) }

    func makeUIView(context: Context) -> TerminalView {
        let terminal = TerminalView(frame: .zero)
        terminal.terminalDelegate = context.coordinator

        // Apply terminal rendering preferences from settings.
        let s = context.coordinator.settings
        terminal.font = UIFont.monospacedSystemFont(ofSize: CGFloat(s.fontSize), weight: .regular)
        terminal.getTerminal().options.scrollback = s.scrollbackLines
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

        // Render PTY output as it arrives (already hopped to main in the bridge).
        output.onBytes = { [weak terminal] bytes in
            terminal?.feed(byteArray: bytes[...])
        }
        return terminal
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {
        // Refresh halo color when theme changes.
        context.coordinator.halo.configure(color: UIColor(Color(theme.bell.edge)))
        // Update mouse-active dot visibility and selection gesture state.
        context.coordinator.updateMouseDot(from: uiView)
    }

    /// Bridges SwiftTerm's delegate callbacks to the SSH session.
    final class Coordinator: NSObject, TerminalViewDelegate {
        private let onSend: ([UInt8]) -> Void
        private let session: ShellSession?
        let settings: TerminalSettings
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
            DispatchQueue.main.asyncAfter(deadline: .now() + ResizeDebounce.quiet) { [weak self] in
                guard let self else { return }
                if let size = self.resizeDebounce.tick(at: Date()) {
                    Task { try? await session?.resize(cols: UInt32(size.cols), rows: UInt32(size.rows)) }
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
            if let gr = selectionLongPress {
                if mouseActive {
                    gr.isEnabled = false
                    // TODO(phase4): also suspend cursor-placement halo here
                } else {
                    gr.isEnabled = true
                }
            }
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

/// Map a `CursorStyle` + blink flag onto SwiftTerm's `CursorStyle` enum and
/// apply it to the given `TerminalView`.
///
/// - Note: SwiftTerm's `CursorStyle` and the `nativeCursorStyle` property are
///   assumed from the SwiftTerm 1.x public API (`.blinkBlock`, `.steadyBlock`,
///   `.blinkUnderline`, `.steadyUnderline`, `.blinkBar`, `.steadyBar`).
///   This mapping is CI-verified on macOS only; it cannot be compiled on Linux.
private func applyCursor(to terminal: TerminalView, style: CursorStyle, blink: Bool) {
    let swiftTermStyle: SwiftTerm.CursorStyle
    switch (style, blink) {
    case (.block, true):       swiftTermStyle = .blinkBlock
    case (.block, false):      swiftTermStyle = .steadyBlock
    case (.underline, true):   swiftTermStyle = .blinkUnderline
    case (.underline, false):  swiftTermStyle = .steadyUnderline
    case (.bar, true):         swiftTermStyle = .blinkBar
    case (.bar, false):        swiftTermStyle = .steadyBar
    }
    terminal.nativeCursorStyle = swiftTermStyle
}
