// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// L4b argument-position denylist. Given a reconstructed line's tokens, returns
/// the indexes whose token is a secret-bearing VALUE (or a `flag=value` token that
/// embeds one) and must never be learned. Conservative, deterministic, typed table
/// — no regex over the whole line, no user-editable rules in v1.
///
/// Reframe: over-suppression is cheap (one skipped word); a missed value leaks a
/// credential — so ambiguous forms drop the value.

/// Flags whose FOLLOWING token (space-separated) or `=`-suffix (joined) is secret.
/// Compared case-insensitively.
private let secretFlags: Set<String> = [
    "-p", "--password", "-P", "--pass", "--token", "--api-key", "--secret", "--passphrase",
]

/// Header tokens whose following token is a credential.
private let secretHeaders: Set<String> = [
    "authorization:", "x-api-key:",
]

/// Indexes of tokens to drop as secret values.
public func secretValueIndexes(in tokens: [String]) -> Set<Int> {
    var drop: Set<Int> = []
    for (i, token) in tokens.enumerated() {
        let lower = token.lowercased()
        // `--flag=value` — the whole token embeds the secret.
        if let eq = token.firstIndex(of: "=") {
            let flagPart = String(token[token.startIndex..<eq]).lowercased()
            if secretFlags.contains(flagPart) { drop.insert(i); continue }
        }
        // bare `--flag` / `-p` → drop the NEXT token (the value), if any.
        if secretFlags.contains(lower), i + 1 < tokens.count {
            drop.insert(i + 1)
            continue
        }
        // header token → drop the single following token.
        if secretHeaders.contains(lower), i + 1 < tokens.count {
            drop.insert(i + 1)
            continue
        }
        // `user:pass@host` connection string → drop the whole token.
        if isUserPassAtHost(token) { drop.insert(i) }
    }
    return drop
}

/// Incremental (per-token) view of the denylist, for the streaming tracker: is
/// `token` a secret VALUE given the token immediately before it? Same rule set as
/// `secretValueIndexes`, sliced to one token + its predecessor.
public func isSecretValueToken(_ token: String, precededBy previous: String?) -> Bool {
    // (b) `--flag=value` token embeds a secret.
    if let eq = token.firstIndex(of: "=") {
        let flagPart = String(token[token.startIndex..<eq]).lowercased()
        if secretFlags.contains(flagPart) { return true }
    }
    // (c) `user:pass@host` connection string.
    if isUserPassAtHost(token) { return true }
    // (a)/(d) previous token is a secret flag or header → this token is the value.
    if let prev = previous?.lowercased(),
       secretFlags.contains(prev) || secretHeaders.contains(prev) {
        return true
    }
    return false
}

/// True if `token` is a `user:pass@host` credential form (non-empty user, pass,
/// host; the `:` precedes the `@`).
private func isUserPassAtHost(_ token: String) -> Bool {
    guard let at = token.firstIndex(of: "@") else { return false }
    let creds = token[token.startIndex..<at]
    let host = token[token.index(after: at)...]
    guard !host.isEmpty, let colon = creds.firstIndex(of: ":") else { return false }
    let user = creds[creds.startIndex..<colon]
    let pass = creds[creds.index(after: colon)...]
    return !user.isEmpty && !pass.isEmpty
}
