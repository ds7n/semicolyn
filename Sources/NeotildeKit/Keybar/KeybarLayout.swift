// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// One keybar slot. 4a shipped the four built-in widgets plus default symbol
/// slots; 4d promotes Fn to a first-class reorderable/removable slot. Custom
/// slots / pinned macros arrive in 4d-2.
public enum KeybarSlot: Equatable, Hashable, Sendable {
    case escPill
    case pad
    case modifier
    case tab
    case fn
    case symbol(String)
    /// A user-created custom slot; resolves to a `CustomSlot` in the library.
    case custom(CustomSlotID)
    /// A macro pinned directly to the bar; resolves to a `Macro` in the library.
    case pinnedMacro(MacroID)
}

extension KeybarSlot: Codable {
    private enum CodingKeys: String, CodingKey { case kind, value }

    /// Stable, forward-safe wire form: `{"kind":"escPill"}` and, for symbols,
    /// `{"kind":"symbol","value":"/"}`. A discriminator (vs Swift's default
    /// enum coding) keeps persisted layouts readable and lets later slices add
    /// new kinds without disturbing the existing schema.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .escPill:  try c.encode("escPill", forKey: .kind)
        case .pad:      try c.encode("pad", forKey: .kind)
        case .modifier: try c.encode("modifier", forKey: .kind)
        case .tab:      try c.encode("tab", forKey: .kind)
        case .fn:       try c.encode("fn", forKey: .kind)
        case .symbol(let s):
            try c.encode("symbol", forKey: .kind)
            try c.encode(s, forKey: .value)
        case .custom(let id):
            try c.encode("custom", forKey: .kind)
            try c.encode(id.raw, forKey: .value)
        case .pinnedMacro(let id):
            try c.encode("pinnedMacro", forKey: .kind)
            try c.encode(id.raw, forKey: .value)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "escPill":  self = .escPill
        case "pad":      self = .pad
        case "modifier": self = .modifier
        case "tab":      self = .tab
        case "fn":       self = .fn
        case "symbol":   self = .symbol(try c.decode(String.self, forKey: .value))
        case "custom":   self = .custom(CustomSlotID(try c.decode(String.self, forKey: .value)))
        case "pinnedMacro":
            self = .pinnedMacro(MacroID(try c.decode(String.self, forKey: .value)))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: c, debugDescription: "unknown keybar slot kind '\(kind)'")
        }
    }
}

/// The keybar's slot composition, split into the locked region (never scrolls)
/// and the horizontally scrollable region. 4d makes this user-editable via the
/// Settings→Keybar editor; mutations enforce the spec's sticky rules.
public struct KeybarLayout: Equatable, Sendable, Codable {
    public let locked: [KeybarSlot]
    public let scroll: [KeybarSlot]
    public init(locked: [KeybarSlot], scroll: [KeybarSlot]) {
        self.locked = locked; self.scroll = scroll
    }

    /// Locked `Esc · Pad · Modifier · Tab`; scroll = six convenience symbols + Fn
    /// (keybar-customization spec "Default locked-left composition" + "Scroll region").
    public static let `default` = KeybarLayout(
        locked: [.escPill, .pad, .modifier, .tab],
        scroll: [.symbol("/"), .symbol("|"), .symbol("~"), .symbol("-"), .symbol("("), .symbol(")"), .fn]
    )

    // MARK: - Sticky rules (spec "Sticky rules summary")

    /// Whether a slot may be deleted. Only the two constrained special widgets
    /// (Esc pill, Pad) are non-removable; every other slot can be removed.
    public static func isRemovable(_ slot: KeybarSlot) -> Bool {
        slot != .escPill && slot != .pad
    }

    /// Whether a slot may be dragged across the locked/scroll divider. Esc pill
    /// and Pad are constrained to the locked region; everything else is free.
    public static func canMoveAcrossDivider(_ slot: KeybarSlot) -> Bool {
        slot != .escPill && slot != .pad
    }

    // MARK: - Invariants

    /// A layout is valid when Esc and Pad each appear exactly once and live in
    /// the locked region, and no slot is duplicated across the bar.
    public var isValid: Bool {
        let all = locked + scroll
        if Set(all).count != all.count { return false }            // no duplicates
        if locked.filter({ $0 == .escPill }).count != 1 { return false }
        if locked.filter({ $0 == .pad }).count != 1 { return false }
        if scroll.contains(.escPill) || scroll.contains(.pad) { return false }
        return true
    }

    // MARK: - Mutations (value semantics; nil when a sticky rule forbids the op)

    /// Returns a layout with `slot` removed, or nil if the slot is not removable
    /// (Esc pill / Pad). Removable-but-absent slots return an unchanged copy.
    public func removing(_ slot: KeybarSlot) -> KeybarLayout? {
        guard KeybarLayout.isRemovable(slot) else { return nil }
        return KeybarLayout(locked: locked.filter { $0 != slot },
                            scroll: scroll.filter { $0 != slot })
    }

    /// Moves `slot` to the opposite region (locked↔scroll), appending it at the
    /// end of the target region. Returns nil if the slot is pinned to locked
    /// (Esc pill / Pad). A slot already in the target region is returned unchanged.
    public func moving(_ slot: KeybarSlot, toScroll: Bool) -> KeybarLayout? {
        guard KeybarLayout.canMoveAcrossDivider(slot) else { return nil }
        var newLocked = locked.filter { $0 != slot }
        var newScroll = scroll.filter { $0 != slot }
        if toScroll { newScroll.append(slot) } else { newLocked.append(slot) }
        return KeybarLayout(locked: newLocked, scroll: newScroll)
    }

    /// Reorders the locked region using `onMove`-style offsets. Within-region
    /// permutation only — never changes membership, so always succeeds.
    public func reorderingLocked(fromOffsets source: IndexSet, toOffset destination: Int) -> KeybarLayout {
        KeybarLayout(locked: KeybarLayout._moved(locked, fromOffsets: source, toOffset: destination),
                     scroll: scroll)
    }

    /// Reorders the scroll region using `onMove`-style offsets.
    public func reorderingScroll(fromOffsets source: IndexSet, toOffset destination: Int) -> KeybarLayout {
        KeybarLayout(locked: locked,
                     scroll: KeybarLayout._moved(scroll, fromOffsets: source, toOffset: destination))
    }

    /// SwiftUI `move(fromOffsets:toOffset:)` semantics, implemented without
    /// depending on the (Apple-only) collection extension so it is Linux-testable.
    static func _moved(_ array: [KeybarSlot], fromOffsets source: IndexSet, toOffset destination: Int) -> [KeybarSlot] {
        let moving = source.sorted().map { array[$0] }
        var result = array
        for index in source.sorted(by: >) { result.remove(at: index) }
        let insertAt = destination - source.filter { $0 < destination }.count
        result.insert(contentsOf: moving, at: insertAt)
        return result
    }
}
