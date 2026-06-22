// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import GlymrKit
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
    @Published var pendingPrompt: HostKeyPrompt?
    private var promptContinuation: CheckedContinuation<Bool, Never>?

    private var connection: Connection?
    private(set) var session: ShellSession?
    /// Shared output sink; the terminal view wires `onBytes` to render into itself.
    let output = TerminalShellOutput()

    /// Show a host-key modal and suspend until the user decides.
    func present(_ prompt: HostKeyPrompt) async -> Bool {
        await withCheckedContinuation { cont in
            promptContinuation = cont
            pendingPrompt = prompt
        }
    }

    /// Called by the view when the user taps a modal button.
    func resolvePrompt(_ trusted: Bool) {
        pendingPrompt = nil
        promptContinuation?.resume(returning: trusted)
        promptContinuation = nil
    }

    /// Find an existing saved host matching (hostName, user) or create + persist one.
    private func findOrCreateHost(hostName: String, port: Int, user: String) throws -> Host {
        let existing = try AppStores.shared.hosts.allHosts()
            .first { $0.hostName == hostName && $0.user.value == user }
        if let existing { return existing }
        let host = Host(id: UUID(), label: hostName, hostName: hostName,
                        user: .explicit(user), port: .explicit(port))
        try AppStores.shared.hosts.saveHost(host)
        return host
    }

    func connect(host: String, port: String, user: String, password: String) {
        if state == .connecting || state == .shell { return }   // ignore re-taps
        state = .connecting
        let addr = "\(host):\(port.isEmpty ? "22" : port)"
        output.onExit = { [weak self] exit in
            self?.state = .failed(exit.error ?? "Session closed")
        }
        Task {
            do {
                let portNum = Int(port) ?? 22
                let hostRecord = try findOrCreateHost(hostName: host, port: portNum, user: user)
                let verifier = TofuHostKeyVerifier(
                    hostID: hostRecord.id, trust: AppStores.shared.trust,
                    present: { [weak self] prompt in await self?.present(prompt) ?? false })
                let conn = try await GlymrSSHCoreFFI.connect(
                    addr: addr, allowLegacy: false, allowDeprecated: false, verifier: verifier)
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
            } catch ConnectError.hostKeyRejected {
                state = .failed("Host key not trusted")
            } catch {
                state = .failed(String(describing: error))
            }
        }
    }
}
