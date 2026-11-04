// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

// Security audit M3: the diagnostics stream pins its TLS certificate on first connect,
// and typed content only leaves the device over that pinned TLS link.

/// What to do with the certificate a diagnostics server presents.
public enum RemoteLogCertDecision: Equatable, Sendable {
    /// Nothing pinned for this server yet: accept and pin `presented`.
    case pinFirst
    /// Matches the pin: accept.
    case match
    /// Differs from the pin: refuse, and ask the user whether to trust the new one.
    case mismatch(pinned: String)
}

/// Decide on the certificate fingerprint `presented` by a server whose pin is `pinned`.
public func remoteLogCertDecision(pinned: String?, presented: String) -> RemoteLogCertDecision {
    guard let pinned, !pinned.isEmpty else { return .pinFirst }
    return pinned == presented ? .match : .mismatch(pinned: pinned)
}

/// The key a pin is stored under: one pin per server and port (host compared without case).
public func remoteLogPinKey(host: String, port: Int) -> String {
    "\(host.lowercased()):\(port)"
}

/// `SHA256:<base64, no padding>` of a DER certificate, the format SSH uses for host keys.
public func certificateFingerprint(der: [UInt8]) -> String {
    let digest = SHA256.hash(data: Data(der))
    let b64 = Data(digest).base64EncodedString()
    return "SHA256:" + b64.replacingOccurrences(of: "=", with: "")
}

/// Whether a line carrying typed content may be streamed over `transport`. Only TLS (whose
/// certificate is pinned) qualifies: UDP and TCP are readable by anyone on the network.
public func remoteLogMaySendContent(transport: LogTransport) -> Bool {
    transport == .tls
}

/// Where diagnostics stream to. Changing any part while keystroke content logging is on
/// turns content logging off (see `keystrokeContentAfterDestinationChange`).
public struct RemoteLogDestination: Equatable, Sendable {
    public var enabled: Bool
    public var host: String
    public var port: Int
    public var transport: LogTransport
    public init(enabled: Bool, host: String, port: Int, transport: LogTransport) {
        self.enabled = enabled; self.host = host; self.port = port; self.transport = transport
    }
}

/// Keystroke content logging after the stream destination changed from `old` to `new`.
/// Any change turns it off, so whoever redirects the stream must turn content logging back
/// on, which asks for Face ID. Without this, someone holding an unlocked phone could point
/// an already-enabled keystroke log at their own server.
public func keystrokeContentAfterDestinationChange(contentOn: Bool, old: RemoteLogDestination,
                                                   new: RemoteLogDestination) -> Bool {
    contentOn && old == new
}
