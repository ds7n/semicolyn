// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Decodes a tmux `%output` data field. tmux escapes `\` as `\\` and any
/// non-passthrough byte as `\` + three octal digits. Returns nil on a malformed
/// escape so the caller can surface a `.malformed` event.
func unescapeTmuxOutput(_ s: Substring) -> [UInt8]? {
    let chars = Array(s)
    var out: [UInt8] = []
    out.reserveCapacity(chars.count)
    var i = 0
    while i < chars.count {
        let c = chars[i]
        if c != "\\" {
            out.append(contentsOf: String(c).utf8)
            i += 1
            continue
        }
        // c == backslash: need an escape body.
        guard i + 1 < chars.count else { return nil }
        if chars[i + 1] == "\\" {
            out.append(0x5C)
            i += 2
            continue
        }
        guard i + 3 < chars.count, let byte = octalByte(chars[i + 1], chars[i + 2], chars[i + 3]) else {
            return nil
        }
        out.append(byte)
        i += 4
    }
    return out
}

/// Three octal digit characters → one byte, or nil if any is not an ASCII octal
/// digit (`0`–`7`) or the value exceeds 255. Validation is strict ASCII: Unicode
/// numerics such as superscripts or Arabic-Indic digits are NOT octal digits, so
/// a malformed escape fails closed (nil) rather than decoding to a wrong byte.
private func octalByte(_ a: Character, _ b: Character, _ c: Character) -> UInt8? {
    func digit(_ ch: Character) -> Int? {
        guard let ascii = ch.asciiValue, (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(ascii) else {
            return nil
        }
        return Int(ascii - UInt8(ascii: "0"))
    }
    guard let x = digit(a), let y = digit(b), let z = digit(c) else { return nil }
    let value = x * 64 + y * 8 + z
    guard value <= 255 else { return nil }
    return UInt8(value)
}
