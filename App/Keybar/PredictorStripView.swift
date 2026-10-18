// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SemicolynKit
import SwiftUI
import UIKit

/// The predictive-input row: a **constant-height** strip of accent chips above the
/// keybar (predictor spec §"Suggestion surface"). The row is ALWAYS present at a fixed
/// 26pt, empty when there are no suggestions, otherwise as many one-line chips as the
/// width allows (Kit `chipsThatFit`; no scrolling). This is what "never reflows the keybar" requires: the earlier design
/// collapsed the row to zero when empty, so a suggestion tick grew the whole input
/// accessory (40→74pt) and jumped the terminal (device 2026-07-24). A fixed height
/// keeps the terminal grid constant in every prediction state; chips fade in/out
/// WITHIN the reserved row, never resizing it.
struct PredictorStripView: View {
    /// Fixed row height (pt). Reserved whether or not suggestions are present, so the
    /// input-accessory height, and thus the terminal grid, never changes. Tuned with
    /// the predictor rework (taller chips, easier to hit).
    static let rowHeight: CGFloat = 26

    /// Horizontal gap between chips.
    private static let chipSpacing: CGFloat = 5
    /// Outer horizontal padding of the chip group (8 each side).
    private static let outerPadding: CGFloat = 16
    /// Width reserved for the trailing eraser button.
    private static let eraserWidth: CGFloat = 27
    /// Chip horizontal padding total (8 each side).
    private static let chipPadding: CGFloat = 16
    private static let chipFontSize: CGFloat = 13

    /// Actions (accept a chip, forget the last line) still route through the VM;
    /// only the observed *suggestion state* comes from the split-out slice, so a
    /// suggestion tick re-renders this strip alone (Plan B §B1).
    let vm: ConnectionViewModel
    @ObservedObject var predictorVM: PredictorViewModel
    @Environment(\.theme) private var theme

    @State private var showForgetToast = false

    private var hasSuggestions: Bool { !predictorVM.suggestions.isEmpty }

    /// Measured chip widths (text width + horizontal padding) in suggestion order.
    private func chipWidths() -> [Double] {
        let font = UIFont.monospacedSystemFont(ofSize: Self.chipFontSize, weight: .regular)
        return predictorVM.suggestions.map { s in
            Double((s.text as NSString).size(withAttributes: [.font: font]).width + Self.chipPadding)
        }
    }

    var body: some View {
        GeometryReader { geo in
            strip(width: geo.size.width)
                // GeometryReader places its child top-leading; keep the chips vertically centred.
                .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
        }
        .frame(height: Self.rowHeight)                 // CONSTANT, reserved even when empty
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
        // Fade chips in/out WITHIN the fixed row, no height change, so the keybar and
        // terminal never reflow. (The old `.move(edge:.bottom)` transition combined with
        // a collapsing row was the reflow source.)
        .animation(.easeInOut(duration: 0.12), value: predictorVM.suggestions)
    }

    private func strip(width: CGFloat) -> some View {
        let available = width - Self.outerPadding - (hasSuggestions ? Self.eraserWidth : 0)
        let shown = chipsThatFit(widths: chipWidths(), available: Double(available),
                                 spacing: Double(Self.chipSpacing))
        let visible = Array(predictorVM.suggestions.prefix(shown).enumerated())
        return HStack(spacing: 0) {
            HStack(spacing: Self.chipSpacing) {
                ForEach(visible, id: \.offset) { index, s in
                    Text(s.text)
                        .font(.system(size: Self.chipFontSize, design: .monospaced))
                        .lineLimit(1)                                   // one line, always
                        .truncationMode(index == 0 ? .middle : .tail)   // only a lone-too-wide first chip truncates
                        .foregroundStyle(Color(theme.predictor.suggestionText))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color(theme.predictor.suggestionBg))
                        .clipShape(Capsule())
                        .onInputClickTap { vm.acceptSuggestion(index: index) }
                }
            }
            .padding(.horizontal, 8)
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
    }
}
