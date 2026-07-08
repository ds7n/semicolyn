// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

/// The predictive-input row: a thin auto-hiding strip of accent chips above the
/// keybar (predictor spec §"Suggestion surface"). Hidden when there are no
/// suggestions; slides in/out; never reflows the keybar.
struct PredictorStripView: View {
    /// Actions (accept a chip, forget the last line) still route through the VM;
    /// only the observed *suggestion state* comes from the split-out slice, so a
    /// suggestion tick re-renders this strip alone (Plan B §B1).
    let vm: ConnectionViewModel
    @ObservedObject var predictorVM: PredictorViewModel
    @Environment(\.theme) private var theme

    @State private var showForgetToast = false

    var body: some View {
        Group {
            if !predictorVM.suggestions.isEmpty {
                HStack(spacing: 0) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(predictorVM.suggestions, id: \.self) { s in
                                Text(s)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(Color(theme.predictor.suggestionText))
                                    .padding(.horizontal, 10).padding(.vertical, 3)
                                    .background(Color(theme.predictor.suggestionBg))
                                    .clipShape(Capsule())
                                    .onInputClickTap { vm.acceptSuggestion(s) }
                            }
                        }
                        .padding(.horizontal, 8)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    // Trailing forget-last-line affordance (L7 surgical forget).
                    Button {
                        vm.forgetLastLine()
                        withAnimation { showForgetToast = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            withAnimation { showForgetToast = false }
                        }
                    } label: {
                        Image(systemName: "eraser")
                            .font(.caption)
                            .foregroundStyle(Color(theme.predictor.suggestionText))
                            .padding(.horizontal, 8)
                            .accessibilityLabel("Forget last line")
                    }
                    .buttonStyle(.plain)
                }
                .frame(height: 24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(theme.predictor.stripBg))
                .overlay(alignment: .trailing) {
                    if showForgetToast {
                        Text("Last line forgotten")
                            .font(.caption2)
                            .foregroundStyle(Color(theme.predictor.suggestionText))
                            .padding(6)
                            .background(Color(theme.predictor.stripBg))
                            .clipShape(Capsule())
                            .padding(.trailing, 36)
                            .transition(.opacity)
                    }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.15, dampingFraction: 0.9), value: predictorVM.suggestions)
    }
}
