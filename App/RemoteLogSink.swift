// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Network
import UIKit
import SemicolynKit

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
    private let hostname: String
    private let queue = DispatchQueue(label: "dev.truepositive.semicolyn.remotelog")
    private var connection: NWConnection?

    init(host: String, port: Int, transport: LogTransport) {
        self.host = NWEndpoint.Host(host)
        self.port = NWEndpoint.Port(rawValue: UInt16(clamping: port)) ?? 6514
        self.transport = transport
        // Syslog HOSTNAME token. MUST NOT use `ProcessInfo.hostName` / `UIDevice.name`:
        // on iOS those do a synchronous mDNS/reverse-DNS lookup that blocks the main
        // thread for seconds AND triggers the Local Network permission prompt (Apple:
        // the local-network alert is triggered by `-[NSProcessInfo hostName]`). This
        // ran in `.onAppear` → opening Diagnostics froze the app. `identifierForVendor`
        // + model are local, instant, and never touch the network.
        let vendorID = UIDevice.current.identifierForVendor?.uuidString.prefix(8) ?? "device"
        self.hostname = "\(UIDevice.current.model)-\(vendorID)"
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
            conn.start(queue: self.queue)
            self.connection = conn
        }
    }

    /// Frame the line and send it fire-and-forget. UDP is datagram-per-line; TCP/TLS are
    /// octet-counted so the receiver can deframe a continuous stream.
    func send(_ line: String) {
        let framed = syslogFrame(message: line, hostname: hostname,
                                 timestamp: Self.timestamp(), transport: transport)
        guard let data = framed.data(using: .utf8) else { return }
        queue.async { [weak self] in
            self?.connection?.send(content: data, completion: .idempotent)
        }
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
                let framed = syslogFrame(message: "semicolyn diagnostics test",
                                         hostname: self.hostname,
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
