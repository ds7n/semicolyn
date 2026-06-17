// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Built-in fallback for `port` per host-config-model resolution table.
private let builtInPort = 22

/// Resolves `port`: per-host value → Defaults value → built-in fallback (22).
/// Verbatim resolution order from the host-config-model spec.
public func resolvePort(host: Host, defaults: Defaults) -> Int {
    if let v = host.port.value { return v }
    if let v = defaults.port.value { return v }
    return builtInPort
}

/// Returns true if saving `savingHostId` with `chain` would loop back through a
/// host already reachable in the chain. Walks `ref` hops via `hosts`.
public func hasCycle(savingHostId: UUID, chain: [JumpHop],
                     in hosts: [UUID: Host]) -> Bool {
    var seen: Set<UUID> = [savingHostId]
    var frontier = chain
    while let hop = frontier.first {
        frontier.removeFirst()
        guard case let .ref(hostId) = hop else { continue }
        if !seen.insert(hostId).inserted { return true }
        if let next = hosts[hostId] { frontier.append(contentsOf: next.resolvedJumpChain) }
    }
    return false
}
