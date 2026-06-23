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

    /// Show a host-key modal and suspend until the user decides. One prompt is
    /// in flight per handshake; if a stale continuation somehow remains, resolve
    /// it as rejected (the safe direction) rather than leaking its task.
    func present(_ prompt: HostKeyPrompt) async -> Bool {
        await withCheckedContinuation { cont in
            promptContinuation?.resume(returning: false)
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

    /// Authenticate `conn` for `host`: if the host references a stored identity
    /// whose private key is available, use publickey; otherwise fall back to the
    /// supplied password. Returns the outcome; the caller maps non-success to a
    /// `.failed` state.
    ///
    /// Publickey-present-but-rejected is NOT silently promoted to password auth —
    /// the outcome is returned as-is (matches the cert-auth no-fallback rule).
    private func authenticate(conn: Connection, user: String, host: Host,
                              defaults: Defaults, password: String) async throws -> AuthOutcome {
        // Resolve the identity through Defaults inheritance, not just the host's explicit value.
        if let identityID = resolveIdentities(host: host, defaults: defaults).first {
            // A genuine Keychain read failure must surface (no `try?`); only a truly
            // absent private key falls back to password (e.g. SE-flavor identity whose
            // key isn't stored on this device).
            if let key = try AppStores.shared.identities.privateKeyOpenSSH(for: identityID) {
                // No silent fallback: a present-but-rejected key returns its outcome.
                return try await conn.authenticatePublickey(user: user, privateKeyOpenssh: key)
            }
        }
        return try await conn.authenticatePassword(user: user, password: password)
    }

    /// Find an existing saved host matching (hostName, user) or create + persist one.
    private func findOrCreateHost(hostName: String, port: Int, user: String) throws -> Host {
        let existing = try AppStores.shared.hosts.allHosts()
            .first { $0.hostName == hostName && ($0.port.value ?? 22) == port && $0.user.value == user }
        if let existing { return existing }
        let host = Host(id: UUID(), label: hostName, hostName: hostName,
                        user: .explicit(user), port: .explicit(port))
        try AppStores.shared.hosts.saveHost(host)
        return host
    }

    /// Connect from a saved `Host` record, using its resolved config and a
    /// caller-supplied password. Does NOT create or modify any host record
    /// (contrast with `connect(host:port:user:password:)` which calls
    /// `findOrCreateHost`). Throws a user-facing `.failed` state if the user
    /// field cannot be resolved.
    func connect(savedHost: Host, password: String) {
        if state == .connecting || state == .shell { return }
        state = .connecting
        let defaults = (try? AppStores.shared.hosts.defaults()) ?? Defaults()
        let user: String
        do {
            user = try resolveUser(host: savedHost, defaults: defaults)
        } catch ResolutionError.userUnset {
            state = .failed("Set a user for this host or in Defaults to connect.")
            return
        } catch {
            state = .failed(String(describing: error))
            return
        }
        let port = resolvePort(host: savedHost, defaults: defaults)
        let addr = "\(savedHost.hostName):\(port)"
        output.onExit = { [weak self] exit in
            self?.state = .failed(exit.error ?? "Session closed")
        }
        Task {
            do {
                let verifier = TofuHostKeyVerifier(
                    hostID: savedHost.id, trust: AppStores.shared.trust,
                    present: { [weak self] prompt in await self?.present(prompt) ?? false })
                let conn = try await GlymrSSHCoreFFI.connect(
                    addr: addr, allowLegacy: false, allowDeprecated: false, verifier: verifier)
                let outcome = try await authenticate(conn: conn, user: user, host: savedHost, defaults: defaults, password: password)
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
            } catch ConnectError.HostKeyRejected {
                state = .failed("Host key not trusted")
            } catch {
                state = .failed(String(describing: error))
            }
        }
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
                let defaults = (try? AppStores.shared.hosts.defaults()) ?? Defaults()
                let verifier = TofuHostKeyVerifier(
                    hostID: hostRecord.id, trust: AppStores.shared.trust,
                    present: { [weak self] prompt in await self?.present(prompt) ?? false })
                let conn = try await GlymrSSHCoreFFI.connect(
                    addr: addr, allowLegacy: false, allowDeprecated: false, verifier: verifier)
                let outcome = try await authenticate(conn: conn, user: user, host: hostRecord, defaults: defaults, password: password)
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
            } catch ConnectError.HostKeyRejected {
                state = .failed("Host key not trusted")
            } catch {
                state = .failed(String(describing: error))
            }
        }
    }
}
