// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// The numeric IP the Mosh UDP session should go to (security audit L2).
///
/// Prefers `peerIP`, the address the SSH connection's socket actually reached: that is
/// the server whose host key was just verified, and the address `mosh-server -s` bound
/// to. A fresh DNS lookup of `hostName` could answer differently (round-robin, a
/// changed or spoofed record) and send the session somewhere unverified. `resolve` is
/// used only when there is no usable peer IP: through a jump host, or an IPv6
/// link-local peer whose zone the string form drops. Returns nil when neither works.
public func moshTargetAddress(peerIP: String?, hostName: String,
                              resolve: (String) -> String?) -> String? {
    if let peerIP, !peerIP.isEmpty, !peerIP.lowercased().hasPrefix("fe80:") {
        return peerIP
    }
    return resolve(hostName)
}
