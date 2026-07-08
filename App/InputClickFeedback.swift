// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import UIKit

/// Mirrors the user's iOS **keyboard feedback** settings for our custom tappable
/// controls (keybar keys, predictor chips, app buttons) so they feel like real
/// keyboard keys.
///
/// iOS does NOT expose the keyboard-feedback settings to apps (you cannot read
/// "is keyboard haptic/sound on?"). The one API that HONORS them is
/// `UIDevice.current.playInputClick()` — it plays the keyboard click/haptic only
/// if/how the user has enabled it. Apple's contract is that it fires inside a view
/// conforming to `UIInputViewAudioFeedback`; the click SOUND in particular needs
/// that context (`InputClickAudioHost` below provides it). The HAPTIC portion is
/// observed to honor the setting more broadly. Because our keybar mounts as a
/// SwiftUI `.safeAreaInset` (not a `UIInputView`), whether the click actually fires
/// from these contexts is DEVICE-VERIFIED — if it is a silent no-op, the pivot is
/// to host these controls inside `InputClickAudioHost` / a real input view.
enum InputClickFeedback {
    /// Play the keyboard click, honoring the user's system keyboard feedback settings.
    static func play() {
        UIDevice.current.playInputClick()
    }
}

/// A `UIView` that conforms to `UIInputViewAudioFeedback` so `playInputClick()` has a
/// valid audio-feedback context. Hosting the tappable controls under this (via
/// `InputClickHost` below) is what lets the click SOUND play when the user has
/// keyboard sound enabled. `enableInputClicksWhenVisible` returning `true` is the
/// required opt-in.
final class InputClickAudioView: UIView, UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}

/// Transparent SwiftUI wrapper that places an `InputClickAudioView` in the hierarchy
/// so descendant taps calling `InputClickFeedback.play()` have the audio-feedback
/// context. Zero-size / non-interactive; purely provides the responder context.
struct InputClickHost: UIViewRepresentable {
    func makeUIView(context: Context) -> InputClickAudioView {
        let v = InputClickAudioView()
        v.isUserInteractionEnabled = false
        v.backgroundColor = .clear
        return v
    }
    func updateUIView(_ uiView: InputClickAudioView, context: Context) {}
}

extension View {
    /// Fire the system-honoring keyboard click when `trigger` changes (i.e. on each
    /// tap that increments a per-view counter). Use a monotonically-changing value
    /// (e.g. a tap counter) so repeated identical taps still fire.
    ///
    /// Prefer `onInputClickTap` below for the common "run this on tap AND click" case.
    func inputClick<T: Equatable>(trigger: T) -> some View {
        onChange(of: trigger) { _, _ in InputClickFeedback.play() }
    }

    /// Attach a tap handler that ALSO plays the system keyboard click. Drop-in for a
    /// slot/chip/button's tap: `.onInputClickTap { vm.keybar.tapTab() }`.
    func onInputClickTap(perform action: @escaping () -> Void) -> some View {
        onTapGesture {
            InputClickFeedback.play()
            action()
        }
    }
}

/// Wrap a `Button`'s action so it also plays the system keyboard click, WITHOUT
/// changing the button's visual style. Per-button opt-in (a global `ButtonStyle`
/// can't add the click without either overriding visuals or resetting the button to
/// the default style, so we wrap the action instead):
///
///     Button("Connect") { connect() }.inputClickAction()   // if using this helper
///
/// In practice we edit each button's action to call `InputClickFeedback.play()`
/// first (see the app-button wiring), which is the least-magic, visual-safe path.
enum InputClickButton {
    /// Compose an action that clicks first, then runs `action`.
    static func wrap(_ action: @escaping () -> Void) -> () -> Void {
        { InputClickFeedback.play(); action() }
    }
}
