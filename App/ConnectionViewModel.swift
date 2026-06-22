// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import GlymrSSHCoreFFI

/// Drives the one MVP flow: connect → password auth → open a raw PTY shell.
/// Retains the live `Connection` and `ShellSession` for the terminal to write to.
@MainActor
final class ConnectionViewModel: ObservableObject {
    enum State: Equatable {
        case idle
        case connecting
        case shell
        case failed(String)
    }

    @Published var state: State = .idle

    private var connection: Connection?
    private(set) var session: ShellSession?
    /// Shared output sink; the terminal view wires `onBytes` to render into itself.
    let output = TerminalShellOutput()

    func connect(host: String, port: String, user: String, password: String) {
        if state == .connecting || state == .shell { return }   // ignore re-taps
        state = .connecting
        let addr = "\(host):\(port.isEmpty ? "22" : port)"
        output.onExit = { [weak self] exit in
            self?.state = .failed(exit.error ?? "Session closed")
        }
        Task {
            do {
                let conn = try await GlymrSSHCoreFFI.connect(
                    addr: addr, allowLegacy: false, allowDeprecated: false,
                    verifier: AutoTrustVerifier())
                let outcome = try await conn.authenticatePassword(user: user, password: password)
                switch outcome {
                case .success:
                    break
                default:
                    state = .failed("Authentication failed")
                    return
                }
                let sess = try await conn.openShell(
                    term: "xterm-256color", cols: 80, rows: 24, output: output)
                connection = conn
                session = sess
                state = .shell
            } catch {
                state = .failed(String(describing: error))
            }
        }
    }
}
