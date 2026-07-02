// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Builds the `mosh-server new` argv used to bootstrap a Mosh session over the SSH
/// channel. `-s` binds to the SSH connection's address; `-c 256` requests 256-color;
/// `-l LANG=…` sets a UTF-8 locale (mosh warns/degrades without one); `-p lo:hi`
/// constrains the UDP port when a range is configured.
public func moshServerCommand(_ config: MoshConfig, locale: String = "en_US.UTF-8") -> [String] {
    var argv = [config.serverPath ?? "mosh-server", "new", "-s", "-c", "256",
                "-l", "LANG=\(locale)"]
    if let range = config.udpPortRange, range.count == 2 {
        argv += ["-p", "\(range[0]):\(range[1])"]
    }
    return argv
}
