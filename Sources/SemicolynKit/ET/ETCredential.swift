// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// A freshly generated ET bootstrap credential. `id` is 16 alphanumeric chars
/// (first three forced to 'X', the upstream legacy-compat marker); `passkey`
/// is 32 alphanumeric chars. The MODERN etserver generates its own credential
/// and returns it via IDPASSKEY, so this pair is the bootstrap-command input
/// and the legacy fallback; the connection uses the server's returned values.
public struct ETCredential: Sendable, Equatable {
    public let id: String
    public let passkey: String
    public init(id: String, passkey: String) { self.id = id; self.passkey = passkey }
}

/// Alphanumeric alphabet (A-Z a-z 0-9), matching ET's `genRandomAlphaNum`.
public let etAlphanumeric: [Character] =
    Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")

/// Generate an ET bootstrap credential using the system CSPRNG.
/// `SystemRandomNumberGenerator` is cryptographically secure on Apple and Linux.
public func etGenerateCredential() -> ETCredential {
    var rng = SystemRandomNumberGenerator()
    func randomAlphaNum(_ n: Int) -> String {
        String((0..<n).map { _ in etAlphanumeric.randomElement(using: &rng)! })
    }
    var id = Array(randomAlphaNum(16))
    id[0] = "X"; id[1] = "X"; id[2] = "X"   // legacy-compat marker (upstream SshSetupHandler)
    return ETCredential(id: String(id), passkey: randomAlphaNum(32))
}
