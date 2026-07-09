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

    /// Fired after any change to the modifier state so an observing UI can
    /// re-render the armed/locked slot visuals. Nil by default (tests opt in).
    public var onModifierChange: (() -> Void)?

    // Modifier gestures (no keystroke emitted).
    public func tapCtrl()  { state.tapCtrl(); onModifierChange?() }
    public func armAlt()   { state.armAlt(); onModifierChange?() }
    public func armShift() { state.armShift(); onModifierChange?() }

    // Keystroke gestures.
    public func tapSymbol(_ c: Character) { fire(.char(c)) }
    public func tapEscape()               { fire(.escape) }
    public func tapTab()                  { fire(.tab) }
    public func arrow(_ d: ArrowDirection) { fire(.arrow(d)) }
    /// Emit a function key F1–F12. Modifiers are not applied to F-keys in v1.
    public func tapFKey(_ n: Int) { fire(.function(n)) }

    /// Emits a macro body as a single coalesced write. A macro is a self-contained
    /// recorded sequence: it carries its own per-event modifiers, so firing it
    /// neither applies nor consumes the globally-armed `ModifierState` — an armed
    /// Ctrl stays armed for the user's next real keystroke.
    public func fireMacro(_ body: [MacroEvent]) {
        let bytes = encodeMacroBody(body, applicationCursorKeys: applicationCursorKeys())
        guard !bytes.isEmpty else { return }
        send(bytes)
    }

    /// Emit a fixed-key swipe secondary. A literal sends its UTF-8 bytes; a key
    /// secondary encodes through `encodeKey` with its modifiers (e.g. Shift-Tab).
    public func emitSecondary(_ value: SecondaryValue) {
        switch value {
        case .literal(let s):
            let bytes = Array(s.utf8)
            if !bytes.isEmpty { send(bytes) }
        case .key(let input, let mods):
            let bytes = encodeKey(input, modifiers: mods, applicationCursorKeys: applicationCursorKeys())
            if !bytes.isEmpty { send(bytes) }
        }
    }

    /// Bytes typed on the terminal keyboard (SwiftTerm delegate). When a keybar
    /// modifier is armed and the input is exactly one printable ASCII byte
    /// (0x20–0x7e), re-encode it through the armed modifiers (e.g. armed Ctrl + 'a'
    /// → 0x01) and consume one-shot arms — so the keybar's Ctrl/Alt/Shift apply to
    /// real keyboard keys, not just keys pressed on the keybar. Anything else
    /// (multi-byte sequences: arrows, paste, already-encoded control bytes) passes
    /// through untouched and does not consume the arm.
    public func keyboardInput(_ bytes: [UInt8]) {
        guard state.hasArmedModifier,
              bytes.count == 1, let b = bytes.first, (0x20...0x7e).contains(b),
              let scalar = Unicode.Scalar(UInt32(b)) else {
            send(bytes)
            return
        }
        let encoded = encodeKey(.char(Character(scalar)), modifiers: state.current(),
                                applicationCursorKeys: applicationCursorKeys())
        send(encoded)
        state.consumeAfterKeystroke()
        onModifierChange?()
    }

    private func fire(_ key: KeyInput) {
        let bytes = encodeKey(key, modifiers: state.current(),
                              applicationCursorKeys: applicationCursorKeys())
        send(bytes)
        state.consumeAfterKeystroke()
        onModifierChange?()
    }
}
