// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SemicolynKit
import SwiftUI

/// The predictive-input row: a **constant-height** strip of equal-width, full-height
/// suggestion slots above the keybar (predictor spec §"Suggestion surface"). The row is
/// ALWAYS present at a fixed height, empty when there are no suggestions, otherwise 3 or
/// 4 slots by width (Kit `suggestionSlotCount`; no scrolling). This is what "never reflows
/// the keybar" requires: the earlier design collapsed the row to zero when empty, so a
/// suggestion tick grew the whole input accessory (40→74pt) and jumped the terminal
/// (device 2026-07-24). A fixed height keeps the terminal grid constant in every
/// prediction state; words fade in/out WITHIN the reserved row, never resizing it.
struct PredictorStripView: View {
    /// Fixed row height (pt). Reserved whether or not suggestions are present, so the
    /// input-accessory height, and thus the terminal grid, never changes. Each slot is the
    /// full row height, so the whole strip is the touch target.
    static let rowHeight: CGFloat = 34

    /// Outer horizontal padding of the slot group (8 each side).
    private static let outerPadding: CGFloat = 16
    /// Width reserved for the trailing eraser button.
    private static let eraserWidth: CGFloat = 27
    private static let slotFontSize: CGFloat = 15

    /// Actions (accept a slot, forget the last line) still route through the VM;
    /// only the observed *suggestion state* comes from the split-out slice, so a
    /// suggestion tick re-renders this strip alone (Plan B §B1).
    let vm: ConnectionViewModel
    @ObservedObject var predictorVM: PredictorViewModel
    @Environment(\.theme) private var theme

    @State private var showForgetToast = false
    /// The word under the finger since touch-down; a re-render mid-press cannot change it.
    @State private var pressedWord: String?

    private var hasSuggestions: Bool { !predictorVM.suggestions.isEmpty }

    var body: some View {
        GeometryReader { geo in
            strip(width: geo.size.width)
                // GeometryReader places its child top-leading; keep the slots vertically centred.
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
        // Fade slots in/out WITHIN the fixed row, no height change, so the keybar and
        // terminal never reflow. (The old `.move(edge:.bottom)` transition combined with
        // a collapsing row was the reflow source.)
        .animation(.easeInOut(duration: 0.12), value: predictorVM.suggestions)
    }

    private func strip(width: CGFloat) -> some View {
        let available = width - Self.outerPadding - (hasSuggestions ? Self.eraserWidth : 0)
        let count = suggestionSlotCount(width: Double(available))
        let words = predictorVM.suggestions.map(\.text)
        return HStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(0..<count, id: \.self) { index in
                    if index > 0 {
                        Rectangle()
                            .fill(Color(theme.text.secondary).opacity(0.25))
                            .frame(width: 1)
                            .padding(.vertical, 6)
                    }
                    slot(index: index, word: words.indices.contains(index) ? words[index] : nil)
                }
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

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
                        .accessibilityLabel("Forget what I just typed")
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// One equal-width, full-height slot. An empty slot is blank and not a button. The tap
    /// accepts only if the slot still holds the word captured at touch-down (Kit `acceptedSuggestionIndex`).
    @ViewBuilder
    private func slot(index: Int, word: String?) -> some View {
        if let word {
            Button {
                let current = predictorVM.suggestions.map(\.text)
                let pressed = pressedWord ?? word
                pressedWord = nil
                guard let accepted = acceptedSuggestionIndex(pressed: pressed, index: index, current: current)
                else { return }
                InputClickFeedback.play()
                vm.acceptSuggestion(index: accepted)
            } label: {
                Text(word)
                    .font(.system(size: Self.slotFontSize, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(Color(theme.predictor.suggestionText))
                    .padding(.horizontal, 6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(SuggestionSlotButtonStyle(
                pressedBackground: Color(theme.predictor.suggestionBg),
                onPressStart: { pressedWord = word }))
        } else {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Transparent on the strip until touched, then the suggestion background while pressed.
private struct SuggestionSlotButtonStyle: ButtonStyle {
    let pressedBackground: Color
    /// Called when the touch lands (isPressed turns true).
    let onPressStart: () -> Void

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? pressedBackground : Color.clear)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed { onPressStart() }
            }
    }
}
