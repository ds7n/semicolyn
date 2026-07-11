// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import UIKit
import SwiftUI
import SemicolynKit

/// The SwiftUI root hosted inside `KeybarInputAccessory`. It owns the
/// `@ObservedObject`s directly (rather than being erased to `AnyView` at the
/// `UIHostingController` boundary), so a change to `keybarSettings.settings` — e.g. the
/// user adding a swipe secondary in the editor — re-evaluates the graph and updates the
/// keybar live, without an app restart.
struct KeybarAccessoryRoot: View {
    @ObservedObject var vm: ConnectionViewModel
    @ObservedObject var keybarSettings: KeybarSettingsStore
    let theme: Theme
    let hardwareKeyboardConnected: Bool

    var body: some View {
        VStack(spacing: 0) {
            PredictorStripView(vm: vm, predictorVM: vm.predictorVM)
            KeybarView(keybarSettings: keybarSettings, vm: vm,
                       hardwareKeyboardConnected: hardwareKeyboardConnected)
        }
        .environment(\.theme, theme)
        .background(Color(theme.surface.panel))
    }
}

/// The keybar's real audio-feedback host. A `UIInputView` conforming to
/// `UIInputViewAudioFeedback`, assigned as the terminal's `inputAccessoryView`, so
/// `UIDevice.playInputClick()` (fired by `.onInputClickTap` on the keybar/predictor)
/// actually plays the keyboard click — mirroring the user's iOS keyboard
/// sound+haptic setting. It renders the existing keybar + predictor SwiftUI via a
/// `UIHostingController<KeybarAccessoryRoot>`. The hosting controller self-sizes from
/// its intrinsic content, so the input view hugs the keyboard with no phantom gap and
/// tracks the predictor strip / hidden-keybar height changes.
final class KeybarInputAccessory: UIInputView, UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }

    private let host: UIHostingController<KeybarAccessoryRoot>

    /// Seed height for the initial frame before self-sizing corrects it (keybar row +
    /// predictor strip ballpark). The real height comes from the hosting controller's
    /// intrinsic content size, not this constant.
    private static let seedHeight: CGFloat = 88

    /// Last height reported by `intrinsicContentSize`, used to invalidate only when the
    /// content actually changes size (avoids a layout feedback loop in `layoutSubviews`).
    private var lastMeasuredHeight: CGFloat = 0

    init(vm: ConnectionViewModel,
         keybarSettings: KeybarSettingsStore,
         theme: Theme,
         hardwareKeyboardConnected: Bool) {
        let root = KeybarAccessoryRoot(vm: vm, keybarSettings: keybarSettings,
                                       theme: theme,
                                       hardwareKeyboardConnected: hardwareKeyboardConnected)
        self.host = UIHostingController(rootView: root)
        // The hosting controller computes its own intrinsic size from the live SwiftUI
        // content; the input view then hugs it (see `intrinsicContentSize`).
        host.sizingOptions = .intrinsicContentSize

        super.init(frame: CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width,
                                 height: Self.seedHeight),
                   inputViewStyle: .keyboard)
        allowsSelfSizing = true
        translatesAutoresizingMaskIntoConstraints = false

        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host.view)
        // Pin leading/trailing/top only — NOT bottom. Pinning the bottom too would
        // force host.view to fill the input view's (seeded 88pt) height, and since
        // `intrinsicContentSize` below measures host.view, that made the measurement
        // circular: input height ← intrinsicContentSize ← host.view height ← input
        // height (88 seed) → the bar rendered double-high with a blank second row
        // (build-32 #4). Leaving the bottom free lets host.view size to its content,
        // and the input view hugs that via `intrinsicContentSize`.
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.view.topAnchor.constraint(equalTo: topAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The SwiftUI content's own ideal height at the current width. Uses
    /// `UIHostingController.sizeThatFits(in:)` — which asks SwiftUI directly "how tall
    /// is your content at this width?" — instead of `systemLayoutSizeFitting` on
    /// `host.view`. The latter resolved against host.view's Auto Layout constraints,
    /// which (when the bottom edge was pinned to the input view) collapsed to the input
    /// view's seed height rather than the content height. `sizeThatFits` is immune to
    /// that: it measures the SwiftUI graph, not the container frame.
    private func contentHeight() -> CGFloat {
        let width = bounds.width > 0 ? bounds.width : UIScreen.main.bounds.width
        let fitted = host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
        return fitted.height > 0 ? fitted.height : Self.seedHeight
    }

    /// Hug the SwiftUI content instead of a hardcoded height so the input view sits flush
    /// against the keyboard (no phantom row) and tracks the predictor strip /
    /// hidden-keybar states.
    override var intrinsicContentSize: CGSize {
        let height = contentHeight()
        lastMeasuredHeight = height
        return CGSize(width: UIView.noIntrinsicMetric, height: height)
    }

    /// Re-measure when the hosted content changes size (predictor strip appearing /
    /// disappearing, keybar hidden toggle) so the input view resizes to match — but only
    /// invalidate when the height actually changed, so we don't spin a layout loop.
    override func layoutSubviews() {
        super.layoutSubviews()
        if abs(contentHeight() - lastMeasuredHeight) > 0.5 {
            invalidateIntrinsicContentSize()
        }
    }
}
