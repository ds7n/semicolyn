// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import SwiftTerm
import GlymrSSHCoreFFI

/// Wraps SwiftTerm's UIKit `TerminalView` for SwiftUI. Output bytes from the
/// Rust PTY (via `TerminalShellOutput.onBytes`) are fed into the terminal;
/// user input and size changes go back out through the `ShellSession`.
struct TerminalScreen: UIViewRepresentable {
    let session: ShellSession
    let output: TerminalShellOutput

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeUIView(context: Context) -> TerminalView {
        let terminal = TerminalView(frame: .zero)
        terminal.terminalDelegate = context.coordinator
        // Render PTY output as it arrives (already hopped to main in the bridge).
        output.onBytes = { [weak terminal] bytes in
            terminal?.feed(byteArray: bytes[...])
        }
        return terminal
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {}

    /// Bridges SwiftTerm's delegate callbacks to the SSH session.
    final class Coordinator: NSObject, TerminalViewDelegate {
        private let session: ShellSession
        init(session: ShellSession) { self.session = session }

        // Keystrokes / pasted bytes from the user → remote PTY.
        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            let payload = Data(data)   // ShellSession.write takes Data (Rust Vec<u8>)
            let session = self.session
            Task { try? await session.write(data: payload) }
        }

        // Grid resize (rotation, layout) → remote window-change.
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            let session = self.session
            Task { try? await session.resize(cols: UInt32(newCols), rows: UInt32(newRows)) }
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
