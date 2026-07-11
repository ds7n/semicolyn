// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Wire transport for the remote diagnostics stream.
public enum LogTransport: String, Sendable, CaseIterable {
    case udp, tcp, tls
}

/// Build one RFC 5424 syslog message for `transport`. Header is
/// `<135>1 <timestamp> <hostname> semicolyn - - - <message>` (PRI 135 = local0·8 +
/// debug; version 1; NILVALUE `-` for procid/msgid/structured-data). TCP and TLS
/// (RFC 6587 / RFC 5425) are octet-counted: the returned string is
/// `<utf8-byte-length> <syslog-message>`. UDP (RFC 5426) is the bare message. An
/// empty hostname becomes `-`. Newlines in `message` are flattened to spaces so the
/// message stays single-line and the octet count is exact.
public func syslogFrame(message: String, hostname: String, timestamp: String,
                        transport: LogTransport) -> String {
    let host = hostname.isEmpty ? "-" : hostname
    let flat = message.replacingOccurrences(of: "\n", with: " ")
    let syslog = "<135>1 \(timestamp) \(host) semicolyn - - - \(flat)"
    switch transport {
    case .udp:
        return syslog
    case .tcp, .tls:
        return "\(syslog.utf8.count) \(syslog)"
    }
}
