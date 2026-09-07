// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

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
/// is configured.
public func moshServerCommand(_ config: MoshConfig, locale: String = "en_US.UTF-8") -> [String] {
    var argv = ["MOSH_SERVER_NETWORK_TMOUT=\(moshServerNetworkTimeoutSeconds)",
                config.serverPath ?? "mosh-server", "new", "-s", "-c", "256",
                "-l", "LANG=\(locale)"]
    if let range = config.udpPortRange, range.count == 2 {
        argv += ["-p", "\(range[0]):\(range[1])"]
    }
    return argv
}
