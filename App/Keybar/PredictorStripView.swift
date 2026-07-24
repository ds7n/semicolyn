// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

/// The predictive-input row: a **constant-height** strip of accent chips above the
/// keybar (predictor spec §"Suggestion surface"). The row is ALWAYS present at a fixed
/// 18pt — empty when there are no suggestions, chips (one line, scroll-overflow) when
/// there are. This is what "never reflows the keybar" requires: the earlier design
/// collapsed the row to zero when empty, so a suggestion tick grew the whole input
/// accessory (40→74pt) and jumped the terminal (device 2026-07-24). A fixed height
/// keeps the terminal grid constant in every prediction state; chips fade in/out
/// WITHIN the reserved row, never resizing it.
struct PredictorStripView: View {
    /// Fixed row height (pt). Reserved whether or not suggestions are present, so the
    /// input-accessory height — and thus the terminal grid — never changes. Tuned with
    /// the tightened keybar (2026-07-24 input-area redesign).
    static let rowHeight: CGFloat = 18

    /// Actions (accept a chip, forget the last line) still route through the VM;
    /// only the observed *suggestion state* comes from the split-out slice, so a
    /// suggestion tick re-renders this strip alone (Plan B §B1).
    let vm: ConnectionViewModel
    @ObservedObject var predictorVM: PredictorViewModel
    @Environment(\.theme) private var theme

    @State private var showForgetToast = false

    private var hasSuggestions: Bool { !predictorVM.suggestions.isEmpty }

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(predictorVM.suggestions, id: \.self) { s in
                        Text(s)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)                                   // one line, always
                            .foregroundStyle(Color(theme.predictor.suggestionText))
                            .padding(.horizontal, 8).padding(.vertical, 1)  // tight capsule
                            .background(Color(theme.predictor.suggestionBg))
                            .clipShape(Capsule())
                            .onInputClickTap { vm.acceptSuggestion(s) }
                    }
                }
                .padding(.horizontal, 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Trailing forget-last-line affordance (L7 surgical forget). Only tappable
            // when there is something learned to forget (i.e. suggestions present).
            if hasSuggestions {
                Button {
                    vm.forgetLastLine()
                    withAnimation { showForgetToast = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        withAnimation { showForgetToast = false }
                    }
                } label: {
                    Image(systemName: "eraser")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(theme.predictor.suggestionText))
                        .padding(.horizontal, 8)
                        .accessibilityLabel("Forget last line")
                }
                .buttonStyle(.plain)
            }
        }
        .frame(height: Self.rowHeight)                 // CONSTANT — reserved even when empty
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(theme.predictor.stripBg))
        .overlay(alignment: .trailing) {
            if showForgetToast {
                Text("Last line forgotten")
                    .font(.caption2)
                    .foregroundStyle(Color(theme.predictor.suggestionText))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color(theme.predictor.stripBg))
                    .clipShape(Capsule())
                    .padding(.trailing, 34)
                    .transition(.opacity)
            }
        }
        // Fade chips in/out WITHIN the fixed row — no height change, so the keybar and
        // terminal never reflow. (The old `.move(edge:.bottom)` transition combined with
        // a collapsing row was the reflow source.)
        .animation(.easeInOut(duration: 0.12), value: predictorVM.suggestions)
    }
}
