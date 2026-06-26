// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Ties the keybar's gesture events to byte output: holds the `ModifierState`,
/// encodes each keystroke with `encodeKey` against the live cursor-key mode, and
/// emits via the injected `send`. Pure (no UIKit); the App's slot views call
/// these methods. Modifier-gesture methods only arm state — they never send.
public final class KeybarInputRouter {
    private var state = ModifierState()
    private let applicationCursorKeys: () -> Bool
    private let send: ([UInt8]) -> Void

    public init(applicationCursorKeys: @escaping () -> Bool, send: @escaping ([UInt8]) -> Void) {
        self.applicationCursorKeys = applicationCursorKeys
        self.send = send
    }

    /// Current arming state, for the UI to render armed/locked slot visuals.
    public var modifiers: ModifierState { state }

    // Modifier gestures (no keystroke emitted).
    public func tapCtrl()       { state.tapCtrl() }
    public func doubleTapCtrl() { state.lockCtrl() }
    public func armAlt()        { state.armAlt() }
    public func armShift()      { state.armShift() }

    // Keystroke gestures.
    public func tapSymbol(_ c: Character) { fire(.char(c)) }
    public func tapEscape()               { fire(.escape) }
    public func tapTab()                  { fire(.tab) }
    public func arrow(_ d: ArrowDirection) { fire(.arrow(d)) }

    private func fire(_ key: KeyInput) {
        let bytes = encodeKey(key, modifiers: state.current(),
                              applicationCursorKeys: applicationCursorKeys())
        send(bytes)
        state.consumeAfterKeystroke()
    }
}
