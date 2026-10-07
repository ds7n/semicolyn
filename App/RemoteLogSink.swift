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
/// Fire-and-forget: `send` never blocks the caller (the log path). While the link is not
/// ready (cold start, or after it dropped) lines are BUFFERED in a bounded `pending`
/// queue (drop-oldest) and flushed in order once a connection reaches `.ready`. The local
/// `DebugLog` buffer retains everything regardless.
///
/// Self-healing: a `.failed` / `.waiting` / unrequested `.cancelled` state, or a send
/// error, marks the link down and schedules a reconnect with exponential backoff
/// (`remoteLogReconnectDelay`: 1, 2, 4, 8, 16, then 30s). Each connection carries a
/// generation number so callbacks from a superseded connection are ignored. The app
/// calls `reconnectIfNeeded()` on foreground to skip the backoff. Before this, a link that
/// died while backgrounded stayed dead until relaunch (device 2026-10-05). This class
/// must never log through `DebugLog` (it IS DebugLog's remote sink: recursion).
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
    /// Identifies the current `connection`. Bumped on every new connection and on
    /// `stop()`; a state callback or send completion captured with an older value is
    /// stale and ignored (no double reconnects, no stale `.ready` flipping `isReady`).
    private var generation = 0
    /// Reconnect attempts since the link was last `.ready` (indexes the backoff).
    private var attempts = 0
    /// The single scheduled backoff reconnect, if any (at most one at a time).
    private var reconnectWork: DispatchWorkItem?
    /// When the link was first seen down (nil while up / before the first connect
    /// failed). Reported as `downFor` in the post-reconnect trace line.
    private var downSince: Date?
    /// Set by `stop()`: no connection, send, or reconnect happens afterwards.
    private var stopped = false

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
        queue.async { [weak self] in self?.connect() }
    }

    /// Open a fresh connection as a new generation, superseding (and cancelling) any
    /// previous one. Caller on `queue`.
    private func connect() {
        guard !stopped else { return }
        generation += 1
        let gen = generation
        // Detach the old connection's handler before cancelling it, so its `.cancelled`
        // is not mistaken for a link drop (the generation guard below also covers it).
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        let conn = NWConnection(host: host, port: port, using: makeParameters())
        conn.stateUpdateHandler = { [weak self] state in
            guard let self, gen == self.generation, !self.stopped else { return }
            self.handleState(state)
        }
        connection = conn
        conn.start(queue: queue)
    }

    /// React to a state change of the CURRENT connection (generation already checked).
    /// Caller on `queue` (the connection was started on it).
    private func handleState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            linkUp()
        case .failed, .waiting:
            // `.waiting` = no viable path right now; NWConnection would sit there, so
            // treat it as down and retry on our own backoff with a fresh connection.
            linkDown()
        case .cancelled:
            // Only reachable for a cancel we did not request: `stop()` sets `stopped` and
            // `connect()` detaches the handler, both filtered before we get here.
            linkDown()
        default:
            break
        }
    }

    /// Link up: stamp the build banner, note the reconnect gap (if this follows a drop),
    /// then flush everything buffered while down (the cold-launch resume trace, or the
    /// lines emitted during the outage). Buffered lines are pre-framed with their
    /// EMIT-time timestamp, so the flushed trace stays in chronological order. The banner
    /// stamps every stream (including one started mid-session or after a reconnect) with
    /// the build/OS/device that produced the trace. Caller on `queue`.
    private func linkUp() {
        isReady = true
        // A link that came up on its own (e.g. out of `.waiting`) supersedes any pending
        // backoff reconnect, which would otherwise tear down this good connection.
        reconnectWork?.cancel()
        reconnectWork = nil
        writeString(syslogFrame(message: BuildBanner.line,
                                timestamp: Self.timestamp(), transport: transport))
        if let since = downSince {
            let downFor = String(format: "%.1f", Date().timeIntervalSince(since))
            writeString(syslogFrame(message: "remoteLog:reconnected attempt=\(attempts) downFor=\(downFor)s",
                                    timestamp: Self.timestamp(), transport: transport))
        }
        attempts = 0
        downSince = nil
        let buffered = pending
        pending.removeAll()
        for framed in buffered { writeString(framed) }
    }

    /// Link down: route new lines to `pending` and schedule a backoff reconnect.
    /// Idempotent per outage (only one reconnect is ever scheduled). Caller on `queue`.
    private func linkDown() {
        isReady = false
        if downSince == nil { downSince = Date() }
        scheduleReconnect()
    }

    /// Schedule ONE reconnect after the backoff delay for the current attempt. No-op if
    /// stopped or one is already scheduled. Caller on `queue`.
    private func scheduleReconnect() {
        guard !stopped, reconnectWork == nil else { return }
        let delay = remoteLogReconnectDelay(attempt: attempts)
        attempts += 1
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reconnectWork = nil
            self.connect()
        }
        reconnectWork = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Foreground recovery: if the link is known down, reconnect NOW instead of waiting
    /// out the backoff (cancel the timer, reset attempts). A link that is up, or the
    /// initial connect still in progress (never yet failed), is left alone so a foreground
    /// at cold launch does not restart a handshake that is about to succeed.
    func reconnectIfNeeded() {
        queue.async { [weak self] in
            guard let self, !self.stopped, !self.isReady, self.downSince != nil else { return }
            self.reconnectWork?.cancel()
            self.reconnectWork = nil
            self.attempts = 0
            self.connect()
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
        guard !stopped else { return }
        let framed = syslogFrame(message: line, timestamp: Self.timestamp(), transport: transport)
        guard isReady else {
            pending.append(framed)
            if pending.count > Self.maxPending { pending.removeFirst(pending.count - Self.maxPending) }
            return
        }
        writeString(framed)
    }

    /// Write an already-framed line to the connection (caller on `queue`, link ready).
    /// A send error on the CURRENT generation means the link died under a `.ready`
    /// state (e.g. the socket was reaped while backgrounded): mark it down and reconnect.
    /// The completion runs on `queue` (the connection's start queue).
    private func writeString(_ framed: String) {
        guard let data = framed.data(using: .utf8) else { return }
        let gen = generation
        connection?.send(content: data, completion: .contentProcessed { [weak self] (error: NWError?) in
            guard let self, error != nil, gen == self.generation, !self.stopped else { return }
            self.linkDown()
        })
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

    /// Fully stop: cancel the connection and any backoff timer; nothing reconnects after.
    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopped = true
            self.generation += 1
            self.reconnectWork?.cancel()
            self.reconnectWork = nil
            self.connection?.stateUpdateHandler = nil
            self.connection?.cancel()
            self.connection = nil
            self.isReady = false
            self.pending.removeAll()
        }
    }

    /// RFC 3339 timestamp with fractional seconds (syslog TIMESTAMP field).
    private static func timestamp() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }
}
