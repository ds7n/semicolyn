// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import SemicolynKit

/// Observable slice holding the predictor strip's suggestion chips, split out of
/// `ConnectionViewModel` (Plan B §B1) so a suggestion recompute invalidates only the
/// predictor-strip views, not the whole session view tree. `ConnectionViewModel`
/// owns an instance and pushes updates via `apply` / `clear`; the keybar/predictor
/// views observe it directly.
@MainActor
final class PredictorViewModel: ObservableObject {
    /// Ranked predictor chips for the current line (empty means no chips). The view
    /// renders them in order and calls `acceptSuggestion(index:)` with a chip's index.
    @Published private(set) var suggestions: [Suggestion] = []

    /// Highest refresh `seq` applied so far. A result carrying a lower or equal seq is
    /// an older line's async result landing after a newer one: it is dropped.
    private var lastAppliedSeq = 0

    /// Surface refresh `seq`'s chips unless a newer refresh was already applied
    /// (`shouldApplyRefresh`); a stale result is dropped and logged `stale=1 applied=0`.
    func apply(_ s: [Suggestion], seq: Int) {
        guard shouldApplyRefresh(seq: seq, lastApplied: lastAppliedSeq) else {
            DebugLog.shared.log(.predictor,
                "predictor:surface count=\(s.count) seq=\(seq) stale=1 applied=0")
            return
        }
        if seq > lastAppliedSeq { lastAppliedSeq = seq }
        suggestions = s
        DebugLog.shared.log(.predictor,
            "predictor:surface count=\(s.count) seq=\(seq) stale=0 applied=1")
    }

    /// Hide every chip now (line committed, line reset, chip tapped, teardown).
    func clear() {
        guard !suggestions.isEmpty else { return }
        suggestions = []
    }
}
