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

    /// Hardware model identifier (e.g. "iPhone15,2") via `uname`, a local syscall, no
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
/// TLS uses `NWProtocolTLS` with certificate verification DISABLED, this targets the
/// developer's own diagnostics host (self-signed cert from `tools/syslog-sink/`), not a
/// general secure channel. Documented and intentional.
final class RemoteLogSink {
    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private let transport: LogTransport
    private let queue = DispatchQueue(label: "dev.truepositive.semicolyn.remotelog")
    private var connection: NWConnection?
    /// True once the connection reached `.ready`. Before that, sends are BUFFERED (see
    /// `pending`) instead of dropped, so the cold-launch window (app init, the resume
    /// decision, first connect) that fires in the ~1-2s before the TLS handshake
    /// completes is not lost. A dropped cold-start trace hid the mosh-reconnect resume
    /// decision (device 2026-09-07). All access on `queue`.
    private var isReady = false
    /// Lines emitted before `.ready`, flushed in order once the link is up. Bounded so a
    /// host that never becomes reachable cannot grow it without limit.
    private var pending: [String] = []
    /// Max buffered pre-ready lines. The cold-start window is a couple hundred lines at
    /// most; past this, oldest are dropped (the local DebugLog buffer still has them).
    private static let maxPending = 500

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
                guard let self else { return }
                if case .ready = state {
                    // Link up: stamp the build banner, then flush everything buffered
                    // during the pre-ready window (the cold-launch resume trace). Buffered
                    // lines are pre-framed with their EMIT-time timestamp, so the flushed
                    // trace stays in chronological order.
                    self.isReady = true
                    self.writeString(syslogFrame(message: BuildBanner.line,
                                                 timestamp: Self.timestamp(), transport: self.transport))
                    let buffered = self.pending
                    self.pending.removeAll()
                    for framed in buffered { self.writeString(framed) }
                }
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

    /// Emit `line` on `queue` (caller must already be on `queue`): frame it with the
    /// current (emit-time) timestamp, then write it if the link is ready, else BUFFER the
    /// framed string for the post-`.ready` flush so the cold-start window is not lost.
    /// Buffer is bounded (drop-oldest) so an unreachable host can't grow it.
    private func sendRaw(_ line: String) {
        let framed = syslogFrame(message: line, timestamp: Self.timestamp(), transport: transport)
        guard isReady else {
            pending.append(framed)
            if pending.count > Self.maxPending { pending.removeFirst(pending.count - Self.maxPending) }
            return
        }
        writeString(framed)
    }

    /// Write an already-framed line to the connection (caller on `queue`, link ready).
    private func writeString(_ framed: String) {
        guard let data = framed.data(using: .utf8) else { return }
        connection?.send(content: data, completion: .idempotent)
    }

    /// Connect (if needed) and send a probe line, reporting whether the connection
    /// reached `.ready`. Used by the Diagnostics "Test connection" button. Resolves to
    /// `false` on failure, cancellation, `.waiting` (no viable path, e.g. unreachable /
    /// firewalled host), or a 5s timeout, so it never hangs the UI.
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
                let framed = syslogFrame(message: "semicolyn diagnostics test, \(BuildBanner.line)",
                                         timestamp: Self.timestamp(), transport: self.transport)
                probe.send(content: framed.data(using: .utf8), completion: .contentProcessed { _ in
                    finish(true)
                })
            case .failed, .cancelled:
                finish(false)
            case .waiting:
                // No viable path (unreachable/firewalled), fail fast rather than retry forever.
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
            self?.isReady = false
            self?.pending.removeAll()
        }
    }

    /// RFC 3339 timestamp with fractional seconds (syslog TIMESTAMP field).
    private static func timestamp() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }
}
