// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

/// Observable slice holding the predictor strip's suggestion chips, split out of
/// `ConnectionViewModel` (Plan B §B1) so a suggestion recompute invalidates only the
/// predictor-strip views, not the whole session view tree. `ConnectionViewModel`
/// owns an instance and pushes updates via `setSuggestions`; the keybar/predictor
/// views observe it directly.
@MainActor
final class PredictorViewModel: ObservableObject {
    /// Top-K predictor chips for the current input token (empty → strip hidden).
    @Published private(set) var suggestions: [String] = []

    /// Highest refresh `seq` surfaced so far. A `setSuggestions` call carrying a LOWER
    /// seq means an older prefix's async results landed after a newer one's (stale-chip
    /// hazard), logged as `stale=1`. Immediate clears pass seq 0 and don't regress it.
    private var lastSurfacedSeq = 0

    func setSuggestions(_ s: [String], seq: Int = 0) {
        suggestions = s
        let stale = seq != 0 && seq < lastSurfacedSeq
        if seq > lastSurfacedSeq { lastSurfacedSeq = seq }
        DebugLog.shared.log(.predictor,
            "predictor:surface count=\(s.count) seq=\(seq) stale=\(stale ? 1 : 0)")
    }
}
