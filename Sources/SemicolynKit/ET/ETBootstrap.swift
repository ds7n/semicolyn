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

/// Parse the `IDPASSKEY:<id>/<passkey>` credential etserver prints on stdout and
/// return the SERVER's credential (mirrors upstream `SshSetupHandler`). The id
/// is 16 chars, the passkey 32, separated by '/'. The output may be embedded in
/// surrounding server noise, so we search for the marker rather than requiring
/// it at the start. Once the marker is found we take a FIXED 49-scalar window
/// immediately after it (16 + 1 + 32, matching upstream ET's
/// `substr(markerEnd, 16+1+32)` in `SshSetupHandler.cpp`) and ignore anything
/// before or after that window: a trailing CR from the SSH PTY, a status token,
/// or other content on the same line must not break parsing. No marker ->
/// `.noIDPASSKEY` with the output sanitized (it is untrusted). A window shorter
/// than 49 scalars, a slash not at index 16, or non-alphanumeric content inside
/// the id/passkey windows -> `.malformedIDPASSKEY`.
public func parseETIDPASSKEY(_ stdout: String) -> Result<ETCredential, ETBootstrapError> {
    let marker = "IDPASSKEY:"
    guard let range = stdout.range(of: marker) else {
        return .failure(.noIDPASSKEY(serverOutput: sanitizeEndReason(stdout)))
    }
    // Match upstream ET (SshSetupHandler.cpp): take the fixed 16 + 1 + 32 = 49
    // character window immediately after the marker, ignoring anything before or
    // after it (a trailing CR / status token / shell banner must not break parsing).
    let after = Array(stdout[range.upperBound...].unicodeScalars)
    guard after.count >= 49 else { return .failure(.malformedIDPASSKEY) }
    let window = Array(after[0..<49])
    guard window[16] == "/" else { return .failure(.malformedIDPASSKEY) }
    let idScalars = window[0..<16]
    let keyScalars = window[17..<49]
    func isAlnum(_ s: Unicode.Scalar) -> Bool {
        (s >= "0" && s <= "9") || (s >= "A" && s <= "Z") || (s >= "a" && s <= "z")
    }
    guard idScalars.allSatisfy(isAlnum), keyScalars.allSatisfy(isAlnum) else {
        return .failure(.malformedIDPASSKEY)
    }
    let id = String(String.UnicodeScalarView(idScalars))
    let passkey = String(String.UnicodeScalarView(keyScalars))
    return .success(ETCredential(id: id, passkey: passkey))
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
