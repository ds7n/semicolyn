// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import SemicolynKit

/// What a flicked keybar key would send if the finger lifted now: the secondary's
/// display label, plus the key's bounds so the accessory root can place the bubble.
struct KeyFlickPreview: Equatable {
    let label: String
    let anchor: Anchor<CGRect>
}

/// Carries the live flick preview from the key being flicked up to
/// `KeybarAccessoryRoot`, which draws the one bubble. Drawing it at the root (not on
/// the key) keeps the middle region's horizontal ScrollView from clipping it.
struct KeyFlickPreferenceKey: PreferenceKey {
    static var defaultValue: KeyFlickPreview? { nil }

    /// At most one key flicks at a time; if two ever publish, the later one wins.
    static func reduce(value: inout KeyFlickPreview?, nextValue: () -> KeyFlickPreview?) {
        value = nextValue() ?? value
    }
}

/// The flick preview bubble, like the iOS key-press popup: a rounded panel-coloured
/// bubble centred over the key with its bottom edge on the key's top, showing the
/// secondary in larger text than the key. Its height is capped at the key's distance
/// to the top of the accessory (`keyRect.minY`, i.e. the predictor strip above it),
/// so it rises over the strip but never leaves the accessory's bounds.
struct KeyFlickBubble: View {
    let label: String
    /// The key's frame in the accessory root's coordinate space.
    let keyRect: CGRect
    /// The accessory root's width, to keep an edge key's bubble on screen.
    let containerWidth: CGFloat
    @Environment(\.theme) private var theme

    private static let fontSize: CGFloat = 24
    private static let cornerRadius: CGFloat = 8
    /// How much taller and wider than the key the bubble wants to be.
    private static let growth: CGFloat = 12
    private static let minWidth: CGFloat = 44

    var body: some View {
        let height = max(0, min(keyRect.height + Self.growth, keyRect.minY))
        let width = min(max(keyRect.width + Self.growth, Self.minWidth), containerWidth)
        let x = min(max(keyRect.midX, width / 2), containerWidth - width / 2)
        Text(label)
            .font(.system(size: Self.fontSize, design: .monospaced))
            .lineLimit(1)
            .minimumScaleFactor(0.4)
            .foregroundStyle(Color(theme.text.primary))
            .padding(.horizontal, 4)
            .frame(width: width, height: height)
            .background(RoundedRectangle(cornerRadius: Self.cornerRadius)
                .fill(Color(theme.surface.panelHigh)))
            .overlay(RoundedRectangle(cornerRadius: Self.cornerRadius)
                .stroke(Color(theme.surface.line), lineWidth: 0.5))
            .position(x: x, y: keyRect.minY - height / 2)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
