// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Wire transport for the remote diagnostics stream.
public enum LogTransport: String, Sendable, CaseIterable {
    case udp, tcp, tls
}

/// Build one RFC 5424 syslog message for `transport`. Header is
/// `<135>1 <timestamp> - semicolyn - - - <message>` (PRI 135 = local0·8 + debug;
/// version 1; NILVALUE `-` for HOSTNAME/procid/msgid/structured-data). The HOSTNAME
/// field is intentionally the nil value `-`: deriving a device name on iOS requires
/// `ProcessInfo.hostName`, which does a synchronous mDNS lookup that blocks the main
/// thread and triggers the Local Network permission prompt — not worth it. The build
/// is identified by the version banner the sink emits on connect instead. TCP and TLS
/// (RFC 6587 / RFC 5425) are octet-counted: the returned string is
/// `<utf8-byte-length> <syslog-message>`. UDP (RFC 5426) is the bare message. Newlines
/// in `message` are flattened to spaces so it stays single-line and the octet count is exact.
public func syslogFrame(message: String, timestamp: String,
                        transport: LogTransport) -> String {
    let flat = message.replacingOccurrences(of: "\n", with: " ")
    let syslog = "<135>1 \(timestamp) - semicolyn - - - \(flat)"
    switch transport {
    case .udp:
        return syslog
    case .tcp, .tls:
        return "\(syslog.utf8.count) \(syslog)"
    }
}
