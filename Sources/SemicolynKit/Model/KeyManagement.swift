// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// OpenSSH public-key type names the SSH Keys screen will show, copy or share.
private let publicKeyTypes: Set<String> = [
    "ssh-ed25519", "ssh-rsa", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521",
    "sk-ssh-ed25519@openssh.com", "sk-ecdsa-sha2-nistp256@openssh.com",
]

/// The `authorized_keys` line for `identity`, as shown, copied and shared on the SSH
/// Keys screen: `<type> <base64> <comment>`. A key with no comment gets the display
/// name (control characters and line breaks folded to spaces) so the server side
/// shows which key it is.
///
/// Built only from the public `Identity.publicKey` field. Returns `nil` when that
/// field doesn't look like exactly one OpenSSH public key line (unknown type, bad
/// base64, more than one line, or anything resembling private key material), so a
/// corrupt record can never put secret bytes on screen or on the clipboard.
public func publicKeyShareText(_ identity: Identity) -> String? {
    let line = identity.publicKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !line.contains("\n"), !line.contains("\r"),
          !line.uppercased().contains("PRIVATE KEY") else { return nil }
    let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
    guard fields.count >= 2, publicKeyTypes.contains(String(fields[0])),
          isBase64(fields[1]), Data(base64Encoded: String(fields[1])) != nil else { return nil }
    if fields.count == 3 { return line }
    let comment = sanitizedComment(identity.displayName)
    return comment.isEmpty ? line : "\(line) \(comment)"
}

extension KeyAlgorithm {
    /// The key type as shown on the SSH Keys screen, e.g. "Ed25519".
    public var displayName: String {
        switch self {
        case .ed25519:   return "Ed25519"
        case .ecdsaP256: return "ECDSA P-256"
        case .ecdsaP384: return "ECDSA P-384"
        case .rsa:       return "RSA"
        }
    }
}

/// The SSH Keys delete confirmation message for a key with `usage`.
public func identityDeleteMessage(_ usage: IdentityUsage) -> String {
    var users = usage.hosts.map(\.label)
    if usage.isDefaultKey { users.append("Connection Defaults") }
    guard !users.isEmpty else { return "No hosts use this key. This can't be undone." }
    let verb = users.count == 1 ? "uses" : "use"
    return "\(englishList(users)) \(verb) this key and will stop using it. This can't be undone."
}

/// "a", "a and b", "a, b and c".
func englishList(_ items: [String]) -> String {
    switch items.count {
    case 0: return ""
    case 1: return items[0]
    default: return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
    }
}

/// True when `field` is non-empty and only base64 alphabet characters.
private func isBase64(_ field: Substring) -> Bool {
    !field.isEmpty && field.unicodeScalars.allSatisfy {
        ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || "+/=".unicodeScalars.contains($0)
    }
}

/// `name` with control characters and line breaks turned into single spaces, trimmed.
private func sanitizedComment(_ name: String) -> String {
    let folded = String(String.UnicodeScalarView(name.unicodeScalars.map {
        CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) ? " " : $0
    }))
    return folded.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
}
