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

/// One of the keybar's three regions. `left` and `right` are pinned to their
/// edges and never scroll; `middle` scrolls horizontally and absorbs the slack.
public enum KeybarRegion: String, CaseIterable, Sendable {
    case left
    case middle
    case right
}

/// The keybar's slot composition across three ordered regions. Mutations are
/// value-semantic and enforce the sticky rules (spec 2026-08-14 Phase 2, revised
/// 2026-10-10): Esc pill and Pad are never deletable and never scroll.
public struct KeybarLayout: Equatable, Sendable {
    public let left: [KeybarSlot]
    public let middle: [KeybarSlot]
    public let right: [KeybarSlot]

    public init(left: [KeybarSlot], middle: [KeybarSlot], right: [KeybarSlot]) {
        self.left = left; self.middle = middle; self.right = right
    }

    /// Left `Esc · Modifier · Tab`; middle = six convenience symbols + Fn; right = Pad.
    public static let `default` = KeybarLayout(
        left: [.escPill, .modifier, .tab],
        middle: [.symbol("/"), .symbol("|"), .symbol("~"), .symbol("-"), .symbol("("), .symbol(")"), .fn],
        right: [.pad]
    )

    /// Every slot on the bar, left to right.
    public var allSlots: [KeybarSlot] { left + middle + right }

    /// The ordered slots of one region.
    public func slots(in region: KeybarRegion) -> [KeybarSlot] {
        switch region {
        case .left:   return left
        case .middle: return middle
        case .right:  return right
        }
    }

    /// The region holding `slot`, or nil when it is not on the bar.
    public func region(of slot: KeybarSlot) -> KeybarRegion? {
        KeybarRegion.allCases.first { slots(in: $0).contains(slot) }
    }

    // MARK: - Sticky rules

    /// Whether a slot may be deleted. Only Esc pill and Pad are non-removable.
    public static func isRemovable(_ slot: KeybarSlot) -> Bool {
        slot != .escPill && slot != .pad
    }

    /// Whether a slot must stay in a fixed region (never scroll off-screen).
    public static func isLockedOnly(_ slot: KeybarSlot) -> Bool {
        slot == .escPill || slot == .pad
    }

    /// The regions a slot may live in, in display order.
    public static func allowedRegions(for slot: KeybarSlot) -> [KeybarRegion] {
        isLockedOnly(slot) ? [.left, .right] : KeybarRegion.allCases
    }

    // MARK: - Invariants

    /// Valid when Esc pill and Pad each appear exactly once in a fixed region and
    /// no slot is duplicated anywhere on the bar.
    public var isValid: Bool {
        let all = allSlots
        if Set(all).count != all.count { return false }
        for constrained in [KeybarSlot.escPill, .pad] {
            if all.filter({ $0 == constrained }).count != 1 { return false }
            if middle.contains(constrained) { return false }
        }
        return true
    }

    // MARK: - Mutations

    /// `slot` removed from whichever region holds it, or nil when the slot is not
    /// removable. A removable-but-absent slot returns an unchanged copy.
    public func removing(_ slot: KeybarSlot) -> KeybarLayout? {
        guard KeybarLayout.isRemovable(slot) else { return nil }
        return filtering { $0 != slot }
    }

    /// `slot` moved to the end of `region`. Nil when the region is not allowed for
    /// the slot (Esc pill / Pad into the middle). Already in `region`: unchanged.
    public func moving(_ slot: KeybarSlot, to region: KeybarRegion) -> KeybarLayout? {
        guard KeybarLayout.allowedRegions(for: slot).contains(region) else { return nil }
        if self.region(of: slot) == region { return self }
        let without = filtering { $0 != slot }
        return without.replacing(region, with: without.slots(in: region) + [slot])
    }

    /// `slot` appended to `region`; unchanged when the slot is already on the bar.
    /// Used by "Add" flows, which must never duplicate a slot.
    public func appending(_ slot: KeybarSlot, to region: KeybarRegion) -> KeybarLayout {
        guard self.region(of: slot) == nil else { return self }
        return replacing(region, with: slots(in: region) + [slot])
    }

    /// Keeps only the slots matching `isIncluded`, in every region.
    public func filtering(_ isIncluded: (KeybarSlot) -> Bool) -> KeybarLayout {
        KeybarLayout(left: left.filter(isIncluded),
                     middle: middle.filter(isIncluded),
                     right: right.filter(isIncluded))
    }

    /// Reorders one region using `onMove`-style offsets; never changes membership.
    public func reordering(_ region: KeybarRegion, fromOffsets source: IndexSet, toOffset destination: Int) -> KeybarLayout {
        replacing(region, with: KeybarLayout._moved(slots(in: region), fromOffsets: source, toOffset: destination))
    }

    // MARK: - v1 migration

    /// Converts a persisted v1 layout (`locked` + `scroll`, optionally shown
    /// mirrored by the retired direction toggle) to three regions.
    /// Non-mirrored: Pad leaves `locked` for the right region, the rest stays left.
    /// Mirrored: the user saw `locked` at the right edge in reverse order, so it
    /// becomes the right region reversed, keeping the bar physically identical.
    public static func fromV1(locked: [KeybarSlot], scroll: [KeybarSlot], mirrored: Bool) -> KeybarLayout {
        if mirrored {
            return KeybarLayout(left: [], middle: scroll, right: Array(locked.reversed()))
        }
        return KeybarLayout(left: locked.filter { $0 != .pad },
                            middle: scroll,
                            right: locked.contains(.pad) ? [.pad] : [])
    }

    // MARK: - Helpers

    private func replacing(_ region: KeybarRegion, with slots: [KeybarSlot]) -> KeybarLayout {
        switch region {
        case .left:   return KeybarLayout(left: slots, middle: middle, right: right)
        case .middle: return KeybarLayout(left: left, middle: slots, right: right)
        case .right:  return KeybarLayout(left: left, middle: middle, right: slots)
        }
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

extension KeybarLayout: Codable {
    private enum CodingKeys: String, CodingKey { case left, middle, right }
    private enum V1Keys: String, CodingKey { case locked, scroll }

    /// v2 payloads (`left`/`middle`/`right`) decode directly. A v1 payload
    /// (`locked`/`scroll`) migrates as non-mirrored; `KeybarSettings` re-derives
    /// the mirrored case because only it knows the retired direction.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let v1 = try decoder.container(keyedBy: V1Keys.self)
        if !c.contains(.left) && v1.contains(.locked) {
            self = KeybarLayout.fromV1(locked: try v1.decode([KeybarSlot].self, forKey: .locked),
                                       scroll: try v1.decode([KeybarSlot].self, forKey: .scroll),
                                       mirrored: false)
            return
        }
        left = try c.decode([KeybarSlot].self, forKey: .left)
        middle = try c.decode([KeybarSlot].self, forKey: .middle)
        right = try c.decode([KeybarSlot].self, forKey: .right)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(left, forKey: .left)
        try c.encode(middle, forKey: .middle)
        try c.encode(right, forKey: .right)
    }
}
