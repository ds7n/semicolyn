// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Build the remote command that plants the ET credential with etserver over an
/// existing SSH session, mirroring upstream `SshSetupHandler::genCommand`:
/// `echo '<id>/<passkey>_<TERM>' | etterminal --verbose=<v>`. When `killUser`
/// is set, prepend a `pkill etterminal -u <user>; sleep 0.5;` (the upstream
/// kill flag) to clear the user's old ET sessions first.
public func etBootstrapCommand(id: String, passkey: String, term: String,
                               verbose: Int = 0, killUser: String? = nil,
                               etterminalPath: String? = nil) -> String {
    let bin = etterminalPath ?? "etterminal"
    let command = "echo '\(id)/\(passkey)_\(term)' | \(bin) --verbose=\(verbose)"
    if let user = killUser {
        return "pkill etterminal -u \(user); sleep 0.5; \(command)"
    }
    return command
}

/// Typed failures of the ET bootstrap (planting + handshake). Each case is
/// distinct so the fallback/UI slice can render the right message. The two
/// string-bearing cases carry ALREADY-SANITIZED text (untrusted server output).
public enum ETBootstrapError: Error, Equatable {
    case execFailed
    case noIDPASSKEY(serverOutput: String)
    case malformedIDPASSKEY
    case invalidConfig(ETConfigError)
    case handshakeFailed(reason: String)
}

/// Parse the `IDPASSKEY:<id>/<passkey>` line etserver prints on stdout and
/// return the SERVER's credential (mirrors upstream `SshSetupHandler`). The id
/// is 16 chars, the passkey 32, separated by '/'. The line may be embedded in
/// surrounding server output, so we search for the marker rather than requiring
/// it at the start. No marker -> `.noIDPASSKEY` with the output sanitized (it is
/// untrusted). Wrong lengths or a missing '/' -> `.malformedIDPASSKEY`.
public func parseETIDPASSKEY(_ stdout: String) -> Result<ETCredential, ETBootstrapError> {
    let marker = "IDPASSKEY:"
    guard let range = stdout.range(of: marker) else {
        return .failure(.noIDPASSKEY(serverOutput: sanitizeEndReason(stdout)))
    }
    // Take the marker's line tail up to the next newline (or end).
    let afterMarker = stdout[range.upperBound...]
    let line = afterMarker.prefix { $0 != "\n" && $0 != "\r" }
    let parts = line.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2, parts[0].count == 16, parts[1].count == 32 else {
        return .failure(.malformedIDPASSKEY)
    }
    return .success(ETCredential(id: String(parts[0]), passkey: String(parts[1])))
}

/// Assemble the live `ETConfig` for `et_connect` from the resolved credential
/// and the terminal geometry, then validate it. Port defaults to ET's 2022.
/// `term` becomes the sole env entry (`TERM`), which `validateETConfig` requires.
/// Throws the specific `ETConfigError` on invalid input.
public func etConnectConfig(host: String, port: UInt16 = 2022, id: String, passkey: String,
                            term: String, cols: UInt16, rows: UInt16) throws -> ETConfig {
    let cfg = ETConfig(host: host, port: port, id: id, passkey: passkey,
                       env: ["TERM": term], cols: cols, rows: rows,
                       width: 0, height: 0, keepaliveSecs: 0)
    return try validateETConfig(cfg)
}
