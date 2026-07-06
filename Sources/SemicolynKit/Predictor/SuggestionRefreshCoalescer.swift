// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
/// Trailing-debounce policy for suggestion recomputation. Each keystroke calls
/// `requestRefresh(at:)`; a check scheduled `quietWindow` later recomputes only if
/// `isDue(at:)` — i.e. no newer request arrived — so a typing burst collapses to a
/// single trailing recompute instead of one per keystroke. Time is injected so the
/// policy is pure and Linux-testable (no wall-clock in Kit).
public struct SuggestionRefreshCoalescer: Sendable {
    public private(set) var lastRequested: Double?
    private let quietWindow: Double

    public init(quietWindow: Double) { self.quietWindow = quietWindow }

    public mutating func requestRefresh(at now: Double) { lastRequested = now }

    public func isDue(at now: Double) -> Bool {
        guard let last = lastRequested else { return false }
        return now - last >= quietWindow
    }
}
