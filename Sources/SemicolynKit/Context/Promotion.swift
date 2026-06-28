// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// One promoted keybar slot: a primary `tap` char plus optional swipe-up /
/// swipe-down secondaries, following the existing per-slot interaction model.
public struct PromotionSlot: Equatable, Sendable, Codable {
    public let tap: String
    public let up: String?
    public let down: String?
    public init(tap: String, up: String? = nil, down: String? = nil) {
        self.tap = tap; self.up = up; self.down = down
    }
}

/// The ordered promotion entries a process contributes to the scrollable keybar.
public struct PromotionSet: Equatable, Sendable, Codable {
    public let promote: [PromotionSlot]
    public init(promote: [PromotionSlot]) { self.promote = promote }
}

/// Process-name → promotion set. The keybar (Phase 4) maps an engaged context to
/// its set; Plan D only needs `knownProcesses` to gate the state machine.
public struct PromotionRegistry: Equatable, Sendable {
    public let sets: [String: PromotionSet]
    public init(sets: [String: PromotionSet]) { self.sets = sets }

    /// The promotion set for `process`, or nil when neither bundled nor overridden.
    public func set(for process: String) -> PromotionSet? { sets[process] }

    /// Names with a promotion set — the only processes the state machine engages on.
    public var knownProcesses: Set<String> { Set(sets.keys) }

    /// Merge `user` over `bundled`: a user entry replaces the bundled set for that
    /// process **whole** (user wins, always); other bundled entries survive.
    public static func merge(bundled: PromotionRegistry, user: PromotionRegistry) -> PromotionRegistry {
        PromotionRegistry(sets: bundled.sets.merging(user.sets) { _, userSet in userSet })
    }

    /// The curated v1 list (context-detection spec §11). `htop`/`top`/`mc` are
    /// Fn-spec auto-engage, not symbol promotions, so they are intentionally absent.
    public static let bundledDefault: PromotionRegistry = {
        func s(_ slots: PromotionSlot...) -> PromotionSet { PromotionSet(promote: slots) }
        let editor = s(.init(tap: ":", up: ";"), .init(tap: "*", up: "#"), .init(tap: "%", up: "^", down: "$"))
        let pager = s(.init(tap: "?"), .init(tap: "<"), .init(tap: ">"))
        let repl = s(.init(tap: ":"), .init(tap: "[", up: "{"), .init(tap: "]", up: "}"), .init(tap: "=", up: "+"))
        let sqlMeta = s(.init(tap: "\\"), .init(tap: ";"))
        return PromotionRegistry(sets: [
            "vim": editor, "nvim": editor,
            "less": pager, "more": pager, "man": pager,
            "python": repl, "python3": repl, "ipython": repl, "node": repl,
            "psql": sqlMeta, "mysql": sqlMeta,
            "sqlite3": s(.init(tap: ";"), .init(tap: ".")),
            "redis-cli": s(.init(tap: ":"), .init(tap: "\\")),
        ])
    }()
}
