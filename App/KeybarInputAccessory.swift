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
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.view.topAnchor.constraint(equalTo: topAnchor),
            host.view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Hug the SwiftUI content instead of a hardcoded height: measure the hosting
    /// controller's compressed fitting size so the input view sits flush against the
    /// keyboard (no phantom row) and tracks the predictor strip / hidden-keybar states.
    override var intrinsicContentSize: CGSize {
        let fitted = host.view.systemLayoutSizeFitting(
            UIView.layoutFittingCompressedSize,
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel)
        let height = fitted.height > 0 ? fitted.height : Self.seedHeight
        lastMeasuredHeight = height
        return CGSize(width: UIView.noIntrinsicMetric, height: height)
    }

    /// Re-measure when the hosted content changes size (predictor strip appearing /
    /// disappearing, keybar hidden toggle) so the input view resizes to match — but only
    /// invalidate when the height actually changed, so we don't spin a layout loop.
    override func layoutSubviews() {
        super.layoutSubviews()
        let fitted = host.view.systemLayoutSizeFitting(
            UIView.layoutFittingCompressedSize,
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel)
        let height = fitted.height > 0 ? fitted.height : Self.seedHeight
        if abs(height - lastMeasuredHeight) > 0.5 {
            invalidateIntrinsicContentSize()
        }
    }
}
