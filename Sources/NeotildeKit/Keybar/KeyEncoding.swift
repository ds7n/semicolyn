// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// A directional arrow key.
public enum ArrowDirection: Equatable, Sendable { case up, down, left, right }

/// A logical key the keybar can emit (before modifiers / terminal mode are applied).
public enum KeyInput: Equatable, Sendable {
    case char(Character)
    case escape
    case tab
    case enter
    case backspace
    case arrow(ArrowDirection)
    case function(Int)   // F1–F12
}

/// The modifier set armed against a keystroke.
public struct KeyModifiers: Equatable, Sendable {
    public var control: Bool
    public var option: Bool
    public var shift: Bool
    public init(control: Bool = false, option: Bool = false, shift: Bool = false) {
        self.control = control; self.option = option; self.shift = shift
    }
}

/// The control byte for `ch` in caret notation, or nil when `ch` has no control
/// form (e.g. a digit). `a`–`z`/`A`–`Z`→1–26, `@A–Z[\]^_`→`&0x1f`, space/`@`→0, `?`→DEL.
private func controlByte(for ch: Character) -> UInt8? {
    guard let a = ch.asciiValue else { return nil }
    switch a {
    case 0x61...0x7a: return a - 0x60          // a-z → 1..26
    case 0x40...0x5f: return a & 0x1f          // @ A-Z [ \ ] ^ _  → 0..31
    case 0x20:        return 0x00              // space → NUL
    case 0x3f:        return 0x7f              // ? → DEL
    default:          return nil
    }
}

/// Encode one logical keystroke to the raw bytes a terminal expects, applying
/// modifiers and the terminal's cursor-key mode (DECCKM). xterm conventions.
public func encodeKey(_ key: KeyInput, modifiers: KeyModifiers, applicationCursorKeys: Bool) -> [UInt8] {
    switch key {
    case .escape:    return [0x1b]
    case .enter:     return [0x0d]
    case .backspace: return [0x7f]
    case .tab:       return modifiers.shift ? Array("\u{1b}[Z".utf8) : [0x09]
    case .arrow(let d):
        let final: Character = { switch d { case .up: return "A"; case .down: return "B"
                                            case .right: return "C"; case .left: return "D" } }()
        let prefix = applicationCursorKeys ? "\u{1b}O" : "\u{1b}["
        return Array((prefix + String(final)).utf8)
    case .function(let n):
        switch n {
        case 1:  return Array("\u{1b}OP".utf8)
        case 2:  return Array("\u{1b}OQ".utf8)
        case 3:  return Array("\u{1b}OR".utf8)
        case 4:  return Array("\u{1b}OS".utf8)
        case 5:  return Array("\u{1b}[15~".utf8)
        case 6:  return Array("\u{1b}[17~".utf8)
        case 7:  return Array("\u{1b}[18~".utf8)
        case 8:  return Array("\u{1b}[19~".utf8)
        case 9:  return Array("\u{1b}[20~".utf8)
        case 10: return Array("\u{1b}[21~".utf8)
        case 11: return Array("\u{1b}[23~".utf8)
        case 12: return Array("\u{1b}[24~".utf8)
        default: return []   // outside F1–F12
        }
    case .char(let ch):
        var base: [UInt8]
        if modifiers.control, let cb = controlByte(for: ch) {
            base = [cb]
        } else {
            let c = modifiers.shift ? Character(ch.uppercased()) : ch
            base = Array(String(c).utf8)
        }
        if modifiers.option { base.insert(0x1b, at: 0) }  // meta-sends-escape
        return base
    }
}
