// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// What a swipe on a fixed key emits: a literal string, or a logical key + modifiers.
public enum SecondaryValue: Equatable, Sendable, Codable {
    case literal(String)
    case key(KeyInput, KeyModifiers)
}

/// The swipe-up / swipe-down secondaries bound to a fixed key. Either may be nil.
public struct SwipeSecondaries: Equatable, Sendable, Codable {
    public var up: SecondaryValue?
    public var down: SecondaryValue?
    public init(up: SecondaryValue? = nil, down: SecondaryValue? = nil) {
        self.up = up; self.down = down
    }
}

/// A stable, Codable identifier for a fixed key — the override-map key.
public enum FixedKeyID: Hashable, Sendable, Codable {
    case symbol(String)
    case tab
    case fkey(Int)
}

/// Built-in swipe secondaries for the fixed keys. Data, not logic: a curated
/// table of sensible defaults. Symbols/keys not listed have no default.
public enum FixedKeyDefaults {
    public static func defaults(for id: FixedKeyID) -> SwipeSecondaries {
        switch id {
        case .tab:
            return SwipeSecondaries(up: .key(.tab, KeyModifiers(shift: true)))  // Shift-Tab
        case .fkey:
            return SwipeSecondaries()  // no natural default; user-overridable
        case .symbol(let s):
            return symbolTable[s] ?? SwipeSecondaries()
        }
    }

    /// Common symbol pairs. Swipe-up = the "shifted/partner" glyph.
    private static let symbolTable: [String: SwipeSecondaries] = [
        "-": SwipeSecondaries(up: .literal("_")),
        "/": SwipeSecondaries(up: .literal("\\")),
        ".": SwipeSecondaries(up: .literal("..")),
        ":": SwipeSecondaries(up: .literal(";")),
        "'": SwipeSecondaries(up: .literal("\"")),
        "`": SwipeSecondaries(up: .literal("~")),
        "|": SwipeSecondaries(up: .literal("&")),
        "=": SwipeSecondaries(up: .literal("+")),
        "*": SwipeSecondaries(up: .literal("^")),
    ]
}

/// Resolve the effective secondaries for a fixed key: a user override replaces
/// the whole pair; otherwise the built-in default; otherwise empty. Never merges
/// per-direction (predictable).
public func resolveSecondaries(for id: FixedKeyID,
                               overrides: [FixedKeyID: SwipeSecondaries]) -> SwipeSecondaries {
    overrides[id] ?? FixedKeyDefaults.defaults(for: id)
}
