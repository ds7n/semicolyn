// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// L4b argument-position denylist. Given a reconstructed line's tokens, returns
/// the indexes whose token is a secret-bearing VALUE (or a `flag=value` token that
/// embeds one) and must never be learned. Conservative, deterministic, typed table
///, no regex over the whole line, no user-editable rules in v1.
///
/// Reframe: over-suppression is cheap (one skipped word); a missed value leaks a
/// credential, so ambiguous forms drop the value.

/// Flags whose FOLLOWING token (space-separated) or `=`-suffix (joined) is secret.
/// Compared case-insensitively.
private let secretFlags: Set<String> = [
    "-p", "--password", "-P", "--pass", "--token", "--api-key", "--secret", "--passphrase",
]

/// Header tokens whose following token is a credential.
private let secretHeaders: Set<String> = [
    "authorization:", "x-api-key:",
]

/// Auth scheme words that sit between a header name and its credential
/// (`Authorization: Bearer <token>`). Compared case-insensitively.
private let authSchemes: Set<String> = [
    "bearer", "basic", "digest", "token", "negotiate", "apikey",
]

/// Variable-name fragments marking `NAME=value` as a secret assignment (the name is
/// uppercased first). `PWD` also matches the shell's working-directory variable:
/// that over-suppression is accepted.
private let secretNameFragments = ["PASS", "PWD", "KEY", "AUTH", "CRED", "TOKEN", "SECRET"]

/// `s` without one leading `'` or `"` (a quoted `-H 'Authorization: ...'` header
/// tokenizes with the quote glued to its first word).
private func strippingLeadingQuote(_ s: String) -> String {
    guard let first = s.first, first == "'" || first == "\"" else { return s }
    return String(s.dropFirst())
}

/// True if `token` is a header-name token (`Authorization:`, `x-api-key:`), allowing
/// one leading quote.
private func isSecretHeader(_ token: String) -> Bool {
    secretHeaders.contains(strippingLeadingQuote(token).lowercased())
}

/// True for `-pSECRET` (mysql style): `-p` plus more text. Case-sensitive, so
/// `-P3306` (a port) is not matched; bare `-p` is handled by `secretFlags`.
private func isJoinedShortPassword(_ token: String) -> Bool {
    token.count > 2 && token.hasPrefix("-p")
}

/// True for `-u user:pass`'s VALUE or the joined forms `-uuser:pass`, `--user=a:b`.
private func isUserCredentialValue(_ token: String, precededBy previous: String?) -> Bool {
    if let prev = previous?.lowercased(), (prev == "-u" || prev == "--user"), token.contains(":") {
        return true
    }
    if token.hasPrefix("--") {
        guard let eq = token.firstIndex(of: "=") else { return false }
        let flagPart = token[token.startIndex..<eq].lowercased()
        return flagPart == "--user" && token[token.index(after: eq)...].contains(":")
    }
    return token.hasPrefix("-u") && token.count > 2 && token.contains(":")
}

/// True for a shell assignment `NAME=value` whose NAME looks secret-bearing.
private func isSecretAssignment(_ token: String) -> Bool {
    guard let eq = token.firstIndex(of: "=") else { return false }
    let name = token[token.startIndex..<eq]
    guard let first = name.first, first == "_" || first.isLetter,
          name.allSatisfy({ $0 == "_" || ($0.isASCII && ($0.isLetter || $0.isNumber)) })
    else { return false }
    let upper = name.uppercased()
    return secretNameFragments.contains { upper.contains($0) }
}

/// Indexes of tokens to drop as secret values.
public func secretValueIndexes(in tokens: [String]) -> Set<Int> {
    var drop: Set<Int> = []
    for (i, token) in tokens.enumerated() {
        let lower = token.lowercased()
        // `--flag=value`, the whole token embeds the secret.
        if let eq = token.firstIndex(of: "=") {
            let flagPart = String(token[token.startIndex..<eq]).lowercased()
            if secretFlags.contains(flagPart) { drop.insert(i); continue }
        }
        // `-psecret`, `-u user:pass`, `--user=a:b`, `NAME_TOKEN=value`.
        if isJoinedShortPassword(token) || isSecretAssignment(token) {
            drop.insert(i)
            continue
        }
        if isUserCredentialValue(token, precededBy: i > 0 ? tokens[i - 1] : nil) {
            drop.insert(i)
            continue
        }
        // bare `--flag` / `-p` → drop the NEXT token (the value), if any.
        if secretFlags.contains(lower), i + 1 < tokens.count {
            drop.insert(i + 1)
            continue
        }
        // header token (optionally quote-prefixed) → drop the following token, and
        // the one after it when that follows an auth scheme (`Bearer <cred>`).
        if isSecretHeader(token), i + 1 < tokens.count {
            drop.insert(i + 1)
            if authSchemes.contains(tokens[i + 1].lowercased()), i + 2 < tokens.count {
                drop.insert(i + 2)
            }
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
///
/// One rule is inherently two tokens deep: the credential after an auth scheme
/// (`Authorization: Bearer abc`). This predicate flags only the scheme word (it
/// follows the header); a stateful caller (the tracker) then drops the token after
/// a scheme that was itself dropped as a header's value, using `isAuthScheme` and
/// `isSecretHeaderToken`. A scheme-looking word elsewhere (`vault token lookup`)
/// never makes its successor secret.
public func isSecretValueToken(_ token: String, precededBy previous: String?) -> Bool {
    // (b) `--flag=value` token embeds a secret.
    if let eq = token.firstIndex(of: "=") {
        let flagPart = String(token[token.startIndex..<eq]).lowercased()
        if secretFlags.contains(flagPart) { return true }
    }
    // (c) `user:pass@host` connection string.
    if isUserPassAtHost(token) { return true }
    // `-psecret`, `-u`-style credentials, `NAME_TOKEN=value`.
    if isJoinedShortPassword(token) || isSecretAssignment(token) { return true }
    if isUserCredentialValue(token, precededBy: previous) { return true }
    // (a)/(d) previous token is a secret flag or header → this token is the value.
    if let prev = previous {
        if secretFlags.contains(prev.lowercased()) || isSecretHeader(prev) { return true }
    }
    return false
}

/// True if `token` is a secret header-name token (`Authorization:`, optionally
/// quote-prefixed). For callers that track the two-token header reach.
public func isSecretHeaderToken(_ token: String) -> Bool { isSecretHeader(token) }

/// True if `token` is an auth scheme word (`Bearer`, `Basic`, ...). Only meaningful
/// directly after a secret header; see `isSecretValueToken`.
public func isAuthScheme(_ token: String) -> Bool {
    authSchemes.contains(token.lowercased())
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
