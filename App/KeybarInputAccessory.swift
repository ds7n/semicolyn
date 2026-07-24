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

    /// Off-screen measuring hosts for the two children, sized independently. We do NOT
    /// measure the live `host` for height: `host.sizeThatFits` proved self-contaminating
    /// on device (2026-07-24) — it returned the accessory's CURRENT frame (90) rather than
    /// the ideal content (56 = 18 strip + 38 bar), because `sizingOptions =
    /// .intrinsicContentSize` feeds the frame back into the measurement, toggling 56↔90 and
    /// leaving dead space above the strip and under the keybar. Fresh, never-framed hosts
    /// measure the true content height stably, so we sum strip + keybar from these instead.
    private let stripMeasureHost: UIHostingController<AnyView>
    private let barMeasureHost: UIHostingController<AnyView>

    /// Seed height for the initial frame before self-sizing corrects it (tightened
    /// keybar row ~33pt + the always-reserved predictor strip 18pt ≈ 51pt; 2026-07-24
    /// input-area redesign). The real height comes from the hosting controller's
    /// intrinsic content size, not this constant.
    private static let seedHeight: CGFloat = 51

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

        // Off-screen measuring hosts (never added to the view tree, never framed) for the
        // two children — measured independently so their heights are stable and free of
        // the live host's frame-feedback (see property doc). Same env/theme as the live
        // graph so the measurement matches what renders.
        self.stripMeasureHost = UIHostingController(
            rootView: AnyView(PredictorStripView(vm: vm, predictorVM: vm.predictorVM)
                .environment(\.theme, theme)))
        self.barMeasureHost = UIHostingController(
            rootView: AnyView(KeybarView(keybarSettings: keybarSettings, vm: vm,
                                         hardwareKeyboardConnected: hardwareKeyboardConnected)
                .environment(\.theme, theme)))
        stripMeasureHost.view.backgroundColor = .clear
        barMeasureHost.view.backgroundColor = .clear

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
        // Not yet laid out (width 0) => `sizeThatFits` returns a degenerate height (the seed).
        // This happens for a freshly-attached accessory on a window switch, and made
        // `firstResponderKeybarHeight` report a transient wrong kbH (40 not 74), thrashing the
        // grid and painting the history seed at the wrong size (device 2026-07-22, the
        // cursor-in-corner switch-back). Fall back to the last VALID measurement, which
        // predictor-strip / hidden-keybar / hardware-keyboard changes keep current.
        guard bounds.width > 0 else {
            return lastMeasuredHeight > 0 ? lastMeasuredHeight : Self.seedHeight
        }
        // Measure the two children INDEPENDENTLY via the off-screen hosts and SUM them,
        // instead of `host.sizeThatFits` on the combined graph. The combined measurement
        // was self-contaminating on device (2026-07-24): it returned the accessory's
        // current frame (90) not the ideal content (56 = 18 + 38), because the live host's
        // `.intrinsicContentSize` sizing feeds its frame back into the measurement — the
        // breakdown probe proved strip=18 and bar=38 are stable while `full` toggled 56↔90.
        // Fresh, never-framed hosts have no frame to feed back, so this is stable.
        let w = bounds.width
        let stripH = stripMeasureHost.sizeThatFits(
            in: CGSize(width: w, height: .greatestFiniteMagnitude)).height
        let barH = barMeasureHost.sizeThatFits(
            in: CGSize(width: w, height: .greatestFiniteMagnitude)).height
        let sum = stripH + barH
        let h = sum > 0 ? sum : Self.seedHeight
        DebugLog.shared.log(.keybar, "keybar:contentHeight h=\(h) strip=\(String(format: "%.1f", stripH)) bar=\(String(format: "%.1f", barH))")
        return h
    }

    /// Hug the SwiftUI content instead of a hardcoded height so the input view sits flush
    /// against the keyboard (no phantom row) and tracks the predictor strip /
    /// hidden-keybar states.
    override var intrinsicContentSize: CGSize {
        let height = contentHeight()
        lastMeasuredHeight = height
        DebugLog.shared.log(.keybar, "keybar:intrinsic h=\(height)")
        return CGSize(width: UIView.noIntrinsicMetric, height: height)
    }

    /// Re-measure when the hosted content changes size (predictor strip appearing /
    /// disappearing, keybar hidden toggle) so the input view resizes to match — but only
    /// invalidate when the height actually changed, so we don't spin a layout loop.
    override func layoutSubviews() {
        super.layoutSubviews()
        let h = contentHeight()
        if abs(h - lastMeasuredHeight) > 0.5 {
            DebugLog.shared.log(.keybar, "keybar:invalidate h=\(h) prev=\(lastMeasuredHeight)")
            invalidateIntrinsicContentSize()
        }
    }
}
