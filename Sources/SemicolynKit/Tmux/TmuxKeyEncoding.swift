// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// The bytes to send AFTER the tmux prefix to trigger a binding whose key `list-keys`
/// reports as `name`. Returns nil for a key we cannot encode (caller falls back to
/// command mode). Covers: printable char, `C-<key>`, named specials, `M-<key>`
/// (Esc-prefixed), arrows (CSI), F1-F12 (SS3/CSI). Arrow/F-key forms are the
/// normal-cursor variants (exotic as action bindings; app-cursor variants deferred).
public func tmuxKeyBytes(_ name: String) -> [UInt8]? {
    let s = name.trimmingCharacters(in: .whitespaces)
    guard !s.isEmpty else { return nil }

    // M-<key>: Esc prefix + the base key's bytes.
    if s.hasPrefix("M-"), s.count > 2 {
        guard let base = tmuxKeyBytes(String(s.dropFirst(2))) else { return nil }
        return [0x1b] + base
    }
    // C-<key>: control byte. Reuse the prefix parser for C-<letter>; handle C-Space.
    if s.hasPrefix("C-") {
        if s == "C-Space" { return [0x00] }
        if let b = parseTmuxPrefix(s) { return [b] }   // "C-a".."C-z" -> 0x01..0x1a
        return nil
    }
    // Named specials.
    switch s {
    case "Space": return [0x20]
    case "Enter", "C-m": return [0x0d]
    case "Tab": return [0x09]
    case "Escape", "Esc": return [0x1b]
    case "BSpace": return [0x7f]
    case "Up": return [0x1b, 0x5b, 0x41]
    case "Down": return [0x1b, 0x5b, 0x42]
    case "Right": return [0x1b, 0x5b, 0x43]
    case "Left": return [0x1b, 0x5b, 0x44]
    default: break
    }
    // Function keys F1-F12 (SS3 for F1-F4, CSI ~ for F5-F12).
    if s.hasPrefix("F"), let n = Int(s.dropFirst()), (1...12).contains(n) {
        let ss3: [Int: UInt8] = [1: 0x50, 2: 0x51, 3: 0x52, 4: 0x53]   // P Q R S
        if let final = ss3[n] { return [0x1b, 0x4f, final] }           // ESC O <final>
        let csi: [Int: [UInt8]] = [
            5: [0x31, 0x35], 6: [0x31, 0x37], 7: [0x31, 0x38], 8: [0x31, 0x39],
            9: [0x32, 0x30], 10: [0x32, 0x31], 11: [0x32, 0x33], 12: [0x32, 0x34]]
        if let mid = csi[n] { return [0x1b, 0x5b] + mid + [0x7e] }      // ESC [ <n> ~
        return nil
    }
    // Single printable ASCII/UTF-8 char.
    if s.count == 1 { return Array(s.utf8) }
    return nil
}
