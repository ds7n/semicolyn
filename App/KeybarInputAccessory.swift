// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import UIKit
import SwiftUI
import SemicolynKit

/// The keybar's real audio-feedback host. A `UIInputView` conforming to
/// `UIInputViewAudioFeedback`, assigned as the terminal's `inputAccessoryView`, so
/// `UIDevice.playInputClick()` (fired by `.onInputClickTap` on the keybar/predictor)
/// actually plays the keyboard click — mirroring the user's iOS keyboard
/// sound+haptic setting. It renders the existing keybar + predictor SwiftUI via a
/// `UIHostingController`. Because an input accessory view does not auto-size from
/// SwiftUI intrinsic content, the height is set explicitly.
final class KeybarInputAccessory: UIInputView, UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }

    private let host: UIHostingController<AnyView>

    /// Approximate keybar row + predictor strip heights. The hosting controller
    /// lays the SwiftUI out within this; refined on device if clipped.
    private static let contentHeight: CGFloat = 88

    init(vm: ConnectionViewModel,
         keybarSettings: KeybarSettingsStore,
         theme: Theme,
         hardwareKeyboardConnected: Bool) {
        let root = VStack(spacing: 0) {
            PredictorStripView(vm: vm, predictorVM: vm.predictorVM)
            KeybarView(keybarSettings: keybarSettings, vm: vm,
                       hardwareKeyboardConnected: hardwareKeyboardConnected)
        }
        .environment(\.theme, theme)
        .background(Color(theme.surface.panel))

        self.host = UIHostingController(rootView: AnyView(root))
        super.init(frame: CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width,
                                 height: Self.contentHeight),
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

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Self.contentHeight)
    }
}
