// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Network
import UIKit
import SemicolynKit

/// One-line build/OS/device identifier, emitted as the first log line when the remote
/// stream connects. Replaces the old syslog HOSTNAME field: it stamps every trace with
/// the build that produced it WITHOUT an mDNS lookup (which blocked the main thread and
/// prompted for Local Network access). e.g. `semicolyn 0.1.0 (build 36) · iOS 18.5 · iPhone15,2`.
enum BuildBanner {
    static let line: String = {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let os = UIDevice.current.systemName + " " + UIDevice.current.systemVersion
        return "semicolyn \(version) (build \(build)) · \(os) · \(deviceModel())"
    }()

    /// Hardware model identifier (e.g. "iPhone15,2") via `uname` — a local syscall, no
    /// network, unlike the user-facing `UIDevice.name` which can also prompt.
    private static func deviceModel() -> String {
        var sysinfo = utsname()
        uname(&sysinfo)
        let raw = withUnsafeBytes(of: &sysinfo.machine) { Data($0) }
        return String(bytes: raw.prefix { $0 != 0 }, encoding: .utf8) ?? UIDevice.current.model
    }
}

/// Streams diagnostic lines to a developer-run syslog server over UDP/TCP/TLS.
/// Fire-and-forget: `send` never blocks the caller (the log path); a line is dropped if
/// the connection isn't ready. The local `DebugLog` buffer retains everything regardless.
///
/// TLS uses `NWProtocolTLS` with certificate verification DISABLED — this targets the
/// developer's own diagnostics host (self-signed cert from `tools/syslog-sink/`), not a
/// general secure channel. Documented and intentional.
final class RemoteLogSink {
    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private let transport: LogTransport
    private let queue = DispatchQueue(label: "dev.truepositive.semicolyn.remotelog")
    private var connection: NWConnection?

    init(host: String, port: Int, transport: LogTransport) {
        self.host = NWEndpoint.Host(host)
        self.port = NWEndpoint.Port(rawValue: UInt16(clamping: port)) ?? 6514
        self.transport = transport
        start()
    }

    private func makeParameters() -> NWParameters {
        switch transport {
        case .udp:
            return .udp
        case .tcp:
            return .tcp
        case .tls:
            // TLS with verification disabled (developer's self-signed diagnostics host).
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_verify_block(
                tls.securityProtocolOptions,
                { _, _, complete in complete(true) },   // accept any certificate
                queue)
            return NWParameters(tls: tls, tcp: .init())
        }
    }

    private func start() {
        queue.async { [weak self] in
            guard let self else { return }
            let conn = NWConnection(host: self.host, port: self.port, using: self.makeParameters())
            // Emit the build banner as the first framed line once the link is ready, so
            // every stream (including one started mid-session or after a reconnect) is
            // stamped with the build/OS/device that produced the trace.
            conn.stateUpdateHandler = { [weak self] state in
                if case .ready = state { self?.sendRaw(BuildBanner.line) }
            }
            conn.start(queue: self.queue)
            self.connection = conn
        }
    }

    /// Frame the line and send it fire-and-forget. UDP is datagram-per-line; TCP/TLS are
    /// octet-counted so the receiver can deframe a continuous stream.
    func send(_ line: String) {
        queue.async { [weak self] in self?.sendRaw(line) }
    }

    /// Frame `line` and write it on `queue` (caller must already be on `queue`).
    private func sendRaw(_ line: String) {
        let framed = syslogFrame(message: line, timestamp: Self.timestamp(), transport: transport)
        guard let data = framed.data(using: .utf8) else { return }
        connection?.send(content: data, completion: .idempotent)
    }

    /// Connect (if needed) and send a probe line, reporting whether the connection
    /// reached `.ready`. Used by the Diagnostics "Test connection" button. Resolves to
    /// `false` on failure, cancellation, `.waiting` (no viable path — e.g. unreachable /
    /// firewalled host), or a 5s timeout — so it never hangs the UI.
    func test(_ completion: @escaping (Bool) -> Void) {
        let probe = NWConnection(host: host, port: port, using: makeParameters())
        var finished = false
        // Serialize `finished` on `queue`; call the user completion at most once.
        func finish(_ ok: Bool) {
            queue.async {
                guard !finished else { return }
                finished = true
                probe.cancel()
                completion(ok)
            }
        }
        probe.stateUpdateHandler = { state in
            switch state {
            case .ready:
                let framed = syslogFrame(message: "semicolyn diagnostics test — \(BuildBanner.line)",
                                         timestamp: Self.timestamp(), transport: self.transport)
                probe.send(content: framed.data(using: .utf8), completion: .contentProcessed { _ in
                    finish(true)
                })
            case .failed, .cancelled:
                finish(false)
            case .waiting:
                // No viable path (unreachable/firewalled) — fail fast rather than retry forever.
                finish(false)
            default:
                break
            }
        }
        probe.start(queue: queue)
        // Defensive timeout: nothing can leave the probe hanging.
        queue.asyncAfter(deadline: .now() + 5) { finish(false) }
    }

    func stop() {
        queue.async { [weak self] in
            self?.connection?.cancel()
            self?.connection = nil
        }
    }

    /// RFC 3339 timestamp with fractional seconds (syslog TIMESTAMP field).
    private static func timestamp() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }
}
