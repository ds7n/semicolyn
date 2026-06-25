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

    func makeCoordinator() -> Coordinator { Coordinator(send: send, session: session, settings: settings) }

    func makeUIView(context: Context) -> TerminalView {
        let terminal = TerminalView(frame: .zero)
        terminal.terminalDelegate = context.coordinator

        // Apply terminal rendering preferences from settings.
        let s = context.coordinator.settings
        terminal.font = UIFont.monospacedSystemFont(ofSize: CGFloat(s.fontSize), weight: .regular)
        terminal.getTerminal().options.scrollback = s.scrollbackLines == Int.max ? Int.max : s.scrollbackLines
        applyCursor(to: terminal, style: s.cursorStyle, blink: s.cursorBlink)

        // Render PTY output as it arrives (already hopped to main in the bridge).
        output.onBytes = { [weak terminal] bytes in
            terminal?.feed(byteArray: bytes[...])
        }
        return terminal
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {}

    /// Bridges SwiftTerm's delegate callbacks to the SSH session.
    final class Coordinator: NSObject, TerminalViewDelegate {
        private let onSend: ([UInt8]) -> Void
        private let session: ShellSession?
        let settings: TerminalSettings

        init(send: @escaping ([UInt8]) -> Void, session: ShellSession?, settings: TerminalSettings) {
            self.onSend = send
            self.session = session
            self.settings = settings
        }

        // Keystrokes / pasted bytes from the user → remote (tmux or raw PTY).
        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            onSend(Array(data))
        }

        // Grid resize (rotation, layout) → remote window-change.
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            let session = self.session
            Task { try? await session?.resize(cols: UInt32(newCols), rows: UInt32(newRows)) }
        }

        // Unused delegate methods (required by the protocol).
        func scrolled(source: TerminalView, position: Double) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func bell(source: TerminalView) {}
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
