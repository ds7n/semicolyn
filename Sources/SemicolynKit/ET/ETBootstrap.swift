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
