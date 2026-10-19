// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// The Hosts list search: hosts whose name, address or own user contains `query`
/// (case-insensitive, surrounding spaces ignored), in their original order. A blank
/// query returns every host.
public func filterHosts(_ hosts: [Host], query: String) -> [Host] {
    let q = query.trimmingCharacters(in: .whitespaces).lowercased()
    guard !q.isEmpty else { return hosts }
    return hosts.filter { host in
        [host.label, host.hostName, host.user.value ?? ""]
            .contains { $0.lowercased().contains(q) }
    }
}

/// A copy of `host` for the Hosts list "Duplicate" action: a new `id`, the label
/// "<label> copy" (then "copy 2", "copy 3", ... while taken), and no saved password
/// (the password secret is keyed to the original host). Everything else is kept.
public func duplicateHost(_ host: Host, id: UUID, existingLabels: [String]) -> Host {
    let taken = Set(existingLabels)
    let base = "\(host.label) copy"
    var label = base
    var n = 2
    while taken.contains(label) {
        label = "\(base) \(n)"
        n += 1
    }
    return Host(id: id, label: label, hostName: host.hostName,
                user: host.user, port: host.port, identities: host.identities,
                proxyJump: host.proxyJump, passwordRef: .inherit,
                localForwards: host.localForwards, remoteForwards: host.remoteForwards,
                dynamicForwards: host.dynamicForwards,
                serverAliveInterval: host.serverAliveInterval,
                serverAliveCountMax: host.serverAliveCountMax,
                compression: host.compression,
                strictHostKeyChecking: host.strictHostKeyChecking,
                forwardAgent: host.forwardAgent,
                preferredAuthentications: host.preferredAuthentications,
                mosh: host.mosh, tailscale: host.tailscale, semicolyn: host.semicolyn,
                transport: host.transport)
}

/// Parse what the user typed in "Connect to user@host…": `[user@]host[:port]`, or a
/// full `ssh://` link. Nil for anything `parseSSHURL` rejects (empty host, bad
/// port, embedded spaces or a path-only string).
public func parseQuickConnectAddress(_ text: String) -> SSHConnectTarget? {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }
    if trimmed.lowercased().hasPrefix("ssh://") { return parseSSHURL(trimmed) }
    guard !trimmed.contains("/") else { return nil }
    return parseSSHURL("ssh://" + trimmed)
}

/// The saved host a quick-connect target refers to: same address, same port (unset
/// counts as 22) and same own user (nil matches a host with no user of its own).
public func savedHost(for target: SSHConnectTarget, in hosts: [Host]) -> Host? {
    let port = target.port ?? 22
    return hosts.first {
        $0.hostName == target.host && ($0.port.value ?? 22) == port && $0.user.value == target.user
    }
}

/// A new host record for a quick-connect target with no saved match: labelled with
/// the address, explicit port (22 when unset), and the target's user (a target with
/// no user inherits the default user).
public func newHost(for target: SSHConnectTarget, id: UUID) -> Host {
    Host(id: id, label: target.host, hostName: target.host,
         user: target.user.map { Inherited.explicit($0) } ?? .inherit,
         port: .explicit(target.port ?? 22))
}
