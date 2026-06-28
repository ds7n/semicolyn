// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// The pure accumulation model behind record mode. The App feeds each captured
/// input surface event via `record`; once "Stop" is tapped the review UI mutates
/// the chip list (delete / insert / reorder) before `makeMacro` bundles it into a
/// named `Macro`. (keybar-customization spec "Record mode".)
public struct MacroRecorder: Equatable, Sendable {
    public private(set) var events: [MacroEvent]

    public init(events: [MacroEvent] = []) {
        self.events = events
    }

    public var isEmpty: Bool { events.isEmpty }

    /// Appends a captured event to the end of the sequence.
    public mutating func record(_ event: MacroEvent) {
        events.append(event)
    }

    /// Removes the chip at `index`; out-of-range indices are ignored.
    public mutating func removeEvent(at index: Int) {
        guard events.indices.contains(index) else { return }
        events.remove(at: index)
    }

    /// Inserts a chip at `index` (clamped to the valid range).
    public mutating func insertEvent(_ event: MacroEvent, at index: Int) {
        let clamped = max(0, min(index, events.count))
        events.insert(event, at: clamped)
    }

    /// Moves the chip at `from` to the `to` insertion point, using SwiftUI
    /// `move(fromOffsets:toOffset:)` semantics (`to` is the pre-removal index), so
    /// the review list's `.onMove` maps straight through. No-op for an
    /// out-of-range `from`.
    public mutating func moveEvent(from: Int, to: Int) {
        guard events.indices.contains(from) else { return }
        let event = events.remove(at: from)
        let insertAt = to > from ? to - 1 : to
        events.insert(event, at: max(0, min(insertAt, events.count)))
    }

    /// Bundles the recorded events into a named macro.
    public func makeMacro(id: MacroID, name: String) -> Macro {
        Macro(id: id, name: name, body: events)
    }
}
