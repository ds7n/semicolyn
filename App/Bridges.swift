// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import GlymrSSHCoreFFI

/// MVP host-key policy: trust on first sight, always. The real trust-on-first-use
/// flow (prompt + persist via the already-built `HostKeyStore`) is the immediate
/// follow-up; this stub keeps the connect path unblocked.
final class AutoTrustVerifier: HostKeyVerifier {
    func verify(info: HostKeyInfo) async -> Bool { true }
}

/// Receives merged stdout/stderr from the Rust PTY pump and forwards it to the
/// UI. The Rust side invokes these callbacks off the main thread, so every
/// hand-off hops to main before touching UIKit/SwiftTerm. Decoupled from the
/// terminal view via closures so this stays SwiftTerm-free.
final class TerminalShellOutput: ShellOutput {
    /// Set by the terminal view to receive output bytes (called on the main thread).
    var onBytes: (([UInt8]) -> Void)?
    /// Set by the view model to learn the session ended (called on the main thread).
    var onExit: ((ShellExit) -> Void)?

    func onOutput(data: Data) {
        let bytes = [UInt8](data)   // UniFFI maps Rust Vec<u8> → Swift Data
        DispatchQueue.main.async { [weak self] in self?.onBytes?(bytes) }
    }

    func onClosed(exit: ShellExit) {
        DispatchQueue.main.async { [weak self] in self?.onExit?(exit) }
    }
}
