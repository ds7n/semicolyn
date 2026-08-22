// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import SemicolynKit

/// Observable slice holding the predictor strip's suggestion chips, split out of
/// `ConnectionViewModel` (Plan B §B1) so a suggestion recompute invalidates only the
/// predictor-strip views, not the whole session view tree. `ConnectionViewModel`
/// owns an instance and pushes updates via `setSuggestions`; the keybar/predictor
/// views observe it directly.
@MainActor
final class PredictorViewModel: ObservableObject {
    /// Top-K predictor chips for the current input token (empty → strip hidden). The view
    /// renders this directly and calls `acceptSuggestion(s)` with a chip's text.
    @Published private(set) var suggestions: [String] = []

    /// Per-chip kind, keyed by chip text, so acceptance can look up how to insert the
    /// tapped chip even though the strip now blends kinds within one refresh (a
    /// completion chip and a next-word chip can both be surfaced at once).
    private(set) var kindByToken: [String: SuggestionKind] = [:]

    /// Highest refresh `seq` surfaced so far. A `setSuggestions` call carrying a LOWER
    /// seq means an older prefix's async results landed after a newer one's (stale-chip
    /// hazard), logged as `stale=1`. Immediate clears pass seq 0 and don't regress it.
    private var lastSurfacedSeq = 0

    /// Surface a blended set of chips, each carrying its own kind (completion vs.
    /// next-word) for correct per-chip acceptance. Named distinctly from
    /// `setSuggestions(_:seq:)` (rather than overloaded on it) because Swift cannot
    /// resolve an empty-array-literal call like `setSuggestions([])` between two
    /// array-literal-accepting overloads, and every existing clear call site passes
    /// `[]` untyped.
    func setChips(_ chips: [(text: String, kind: SuggestionKind)], seq: Int = 0) {
        suggestions = chips.map { $0.text }
        kindByToken = Dictionary(chips.map { ($0.text, $0.kind) }, uniquingKeysWith: { a, _ in a })
        let stale = seq != 0 && seq < lastSurfacedSeq
        if seq > lastSurfacedSeq { lastSurfacedSeq = seq }
        DebugLog.shared.log(.predictor,
            "predictor:surface count=\(suggestions.count) seq=\(seq) stale=\(stale ? 1 : 0)")
    }

    /// Convenience for uniform-kind (or empty-clear) call sites: maps every chip to
    /// `.completeWord`. Keeps all existing `setSuggestions([])` clear calls unchanged.
    func setSuggestions(_ s: [String], seq: Int = 0) {
        setChips(s.map { ($0, .completeWord) }, seq: seq)
    }
}
