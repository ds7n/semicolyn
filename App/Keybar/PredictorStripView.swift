// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

/// The predictive-input row: a thin auto-hiding strip of accent chips above the
/// keybar (predictor spec §"Suggestion surface"). Hidden when there are no
/// suggestions; slides in/out; never reflows the keybar.
struct PredictorStripView: View {
    @ObservedObject var vm: ConnectionViewModel
    @Environment(\.theme) private var theme

    var body: some View {
        Group {
            if !vm.predictorSuggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(vm.predictorSuggestions, id: \.self) { s in
                            Text(s)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(Color(theme.predictor.suggestionText))
                                .padding(.horizontal, 10).padding(.vertical, 3)
                                .background(Color(theme.predictor.suggestionBg))
                                .clipShape(Capsule())
                                .onTapGesture { vm.acceptSuggestion(s) }
                        }
                    }
                    .padding(.horizontal, 8)
                }
                .frame(height: 24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(theme.predictor.stripBg))
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.15, dampingFraction: 0.9), value: vm.predictorSuggestions)
    }
}
