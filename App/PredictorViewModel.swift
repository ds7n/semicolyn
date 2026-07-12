// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

/// Observable slice holding the predictor strip's suggestion chips, split out of
/// `ConnectionViewModel` (Plan B §B1) so a suggestion recompute invalidates only the
/// predictor-strip views — not the whole session view tree. `ConnectionViewModel`
/// owns an instance and pushes updates via `setSuggestions`; the keybar/predictor
/// views observe it directly.
@MainActor
final class PredictorViewModel: ObservableObject {
    /// Top-K predictor chips for the current input token (empty → strip hidden).
    @Published private(set) var suggestions: [String] = []

    func setSuggestions(_ s: [String]) {
        suggestions = s
        DebugLog.shared.log(.predictor, "predictor:surface count=\(s.count)")
    }
}
