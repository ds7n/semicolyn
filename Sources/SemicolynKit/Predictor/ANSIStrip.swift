// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Strip ANSI/VT escape sequences and stray control bytes from terminal output so
/// downstream tokenizing (the predictor's output harvest) sees visible text, not
/// color codes. Removes:
///   - CSI: `ESC [` … up to and including a final byte in 0x40–0x7e (SGR colors,
///     erase-in-line, cursor moves, etc.);
///   - OSC: `ESC ]` … up to a BEL (0x07) or ST (`ESC \`);
///   - other `ESC`-introduced two-byte sequences;
///   - lone C0 control bytes and DEL, EXCEPT `\n` and `\t` which are real token
///     separators the caller still splits on.
/// Printable text (including spaces) passes through unchanged.
public func stripANSI(_ input: String) -> String {
    let bytes = Array(input.utf8)
    var out: [UInt8] = []
    out.reserveCapacity(bytes.count)
    var i = 0
    while i < bytes.count {
        let b = bytes[i]
        if b == 0x1b {                              // ESC
            let next = i + 1 < bytes.count ? bytes[i + 1] : 0
            if next == 0x5b {                       // CSI: ESC [ … final 0x40–0x7e
                i += 2
                while i < bytes.count, !(0x40...0x7e).contains(bytes[i]) { i += 1 }
                if i < bytes.count { i += 1 }        // consume the final byte
            } else if next == 0x5d {                // OSC: ESC ] … BEL or ST (ESC \)
                i += 2
                while i < bytes.count {
                    if bytes[i] == 0x07 { i += 1; break }               // BEL
                    if bytes[i] == 0x1b, i + 1 < bytes.count, bytes[i + 1] == 0x5c { i += 2; break } // ST
                    i += 1
                }
            } else {
                i += 2                              // other ESC x two-byte sequence
            }
            continue
        }
        // Keep newline/tab (token separators) and all printable bytes; drop other
        // C0 controls (CR, BEL, backspace, …) and DEL.
        if b == 0x0a || b == 0x09 || (b >= 0x20 && b != 0x7f) {
            out.append(b)
        }
        i += 1
    }
    return String(decoding: out, as: UTF8.self)
}
