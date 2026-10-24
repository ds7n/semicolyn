// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// One trusted host key on the Known Hosts screen.
public struct KnownHostRow: Equatable, Sendable, Identifiable {
    public let hostID: UUID
    public let hostLabel: String
    public let hostName: String
    /// The stored algorithm name, e.g. `ssh-ed25519` (what removal and trust key on).
    public let algorithm: String
    /// The fingerprint exactly as stored (removal matches on this).
    public let fingerprint: String
    public let addedAt: Date

    public init(hostID: UUID, hostLabel: String, hostName: String, algorithm: String,
                fingerprint: String, addedAt: Date) {
        self.hostID = hostID; self.hostLabel = hostLabel; self.hostName = hostName
        self.algorithm = algorithm; self.fingerprint = fingerprint; self.addedAt = addedAt
    }

    /// Stable per host and key.
    public var id: String { "\(hostID.uuidString)|\(algorithm)|\(fingerprint)" }

    /// The friendly key type, e.g. "Ed25519" (`hostKeyTypeLabel`).
    public var keyType: String { hostKeyTypeLabel(algorithm) }

    /// The fingerprint as shown: always `SHA256:<base64>` (`Fingerprint.sha256Display`).
    public var displayFingerprint: String { Fingerprint(fingerprint).sha256Display }
}

/// Every trusted key of every saved host, sorted by host label (case-insensitive),
/// then host id, then the date the key was added. `entries` reads one host's keys
/// (`HostKeyStore.entries(forHost:)`); a host whose keys can't be read is skipped so
/// one corrupt record doesn't empty the screen.
public func knownHostRows(hosts: [SemicolynKit.Host], entries: (UUID) throws -> [HostKey]) -> [KnownHostRow] {
    let sortedHosts = hosts.sorted {
        let a = $0.label.lowercased(), b = $1.label.lowercased()
        return a != b ? a < b : $0.id.uuidString < $1.id.uuidString
    }
    return sortedHosts.flatMap { host -> [KnownHostRow] in
        guard let keys = try? entries(host.id) else { return [] }
        return keys.sorted { $0.addedAt < $1.addedAt }.map {
            KnownHostRow(hostID: host.id, hostLabel: host.label, hostName: host.hostName,
                         algorithm: $0.algorithm, fingerprint: $0.fingerprint, addedAt: $0.addedAt)
        }
    }
}

/// A friendly name for an SSH host-key algorithm; an unknown name is returned as is.
public func hostKeyTypeLabel(_ algorithm: String) -> String {
    switch algorithm {
    case "ssh-ed25519":                        return "Ed25519"
    case "sk-ssh-ed25519@openssh.com":         return "Ed25519 (security key)"
    case "ecdsa-sha2-nistp256":                return "ECDSA P-256"
    case "ecdsa-sha2-nistp384":                return "ECDSA P-384"
    case "ecdsa-sha2-nistp521":                return "ECDSA P-521"
    case "sk-ecdsa-sha2-nistp256@openssh.com": return "ECDSA P-256 (security key)"
    case "ssh-rsa", "rsa-sha2-256", "rsa-sha2-512": return "RSA"
    case "ssh-dss":                            return "DSA"
    default:                                   return algorithm
    }
}

/// The Known Hosts removal confirmation message.
public let knownHostRemoveMessage = "The next connection will ask you to trust this host again."
