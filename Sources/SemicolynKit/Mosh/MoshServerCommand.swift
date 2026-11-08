// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Seconds a mosh-server waits with NO connected client before self-terminating,
/// exported as `MOSH_SERVER_NETWORK_TMOUT`. mosh-server has NO default no-client
/// timeout (it waits forever, since UDP gives it no way to tell "client killed" from
/// "client on a plane"), so an iOS app kill (which sends no disconnect) leaks a server
/// that runs until reboot. Capping it makes an abandoned server self-reap. 1 week is
/// long enough to never cut short a real roaming gap, short enough to bound the leak.
public let moshServerNetworkTimeoutSeconds = 604_800   // 7 days

/// Builds the `mosh-server new` bootstrap invocation, run over the SSH channel as a
/// space-joined shell command. The first element is a `MOSH_SERVER_NETWORK_TMOUT=…`
/// ENV-ASSIGNMENT PREFIX (a POSIX `VAR=val cmd` form when joined), so the spawned
/// mosh-server inherits the abandoned-session timeout. Then: `-s` binds to the SSH
/// connection's address; `-c 256` requests 256-color; `-l LANG=…` sets a UTF-8 locale
/// (mosh warns/degrades without one); `-p lo:hi` constrains the UDP port when a range
/// is configured. A non-nil `sessionCommand` follows `--`: mosh-server runs it instead
/// of the login shell. It is ONE already-quoted shell fragment (e.g. the
/// `plainTmuxDirectLaunchCommand` `sh -c '...'` string), appended verbatim as the last
/// element so the space-joined command hands it to the login shell unchanged; nil leaves
/// the argv exactly as without it. A custom `serverPath` is passed through `shellWord` so
/// spaces or shell metacharacters in it cannot split or inject (security audit L3); a
/// blank one falls back to `mosh-server` on the PATH.
/// The locale comes from `moshLocaleCandidates` and is shell-quoted as well, so even an
/// unexpected value stays one word.
public func moshServerCommand(_ config: MoshConfig, locale: String = moshFallbackLocale,
                              sessionCommand: String? = nil) -> [String] {
    let customPath = config.serverPath?.trimmingCharacters(in: .whitespaces) ?? ""
    let server = customPath.isEmpty ? "mosh-server" : shellWord(customPath)
    var argv = ["MOSH_SERVER_NETWORK_TMOUT=\(moshServerNetworkTimeoutSeconds)",
                server, "new", "-s", "-c", "256",
                "-l", shellWord("LANG=\(locale)")]
    if let range = config.udpPortRange, range.count == 2 {
        argv += ["-p", "\(range[0]):\(range[1])"]
    }
    if let sessionCommand {
        argv += ["--", sessionCommand]
    }
    return argv
}
