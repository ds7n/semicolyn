// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Holds one `PaneContextMachine` per live pane and applies whole `list-panes`
/// snapshots. The per-pane observable from the context-detection spec
/// ("`PaneState.currentContext`"); the keybar (Phase 4) is the only consumer.
public struct PaneContextStore: Sendable {
    private var machines: [PaneID: PaneContextMachine] = [:]
    private let knownProcesses: Set<String>

    public init(knownProcesses: Set<String>) { self.knownProcesses = knownProcesses }

    /// Apply one full snapshot of `(pane, pane_current_command)` readings. Creates
    /// a machine for new panes, prunes panes absent from the snapshot (closed),
    /// and returns the panes whose `engagedContext` changed this call.
    @discardableResult
    public mutating func observe(_ readings: [(PaneID, String)], at now: TimeInterval) -> Set<PaneID> {
        var changed: Set<PaneID> = []
        var live: Set<PaneID> = []
        for (pane, process) in readings {
            live.insert(pane)
            var machine = machines[pane] ?? PaneContextMachine(knownProcesses: knownProcesses)
            if machine.observe(process, at: now) { changed.insert(pane) }
            machines[pane] = machine
        }
        machines = machines.filter { live.contains($0.key) }   // prune closed panes
        return changed
    }

    /// The pane's engaged context, read immediately (no re-debounce on focus change).
    public func context(for pane: PaneID) -> String? { machines[pane]?.engagedContext }
}
