// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Bytes to send for pasting `text`. When `bracketed`, wrap the UTF-8 payload in the
/// xterm bracketed-paste markers `ESC[200~` ... `ESC[201~` so the receiving app treats it
/// as pasted text (multi-line stays intact, editors do not auto-indent it, shells do not
/// auto-execute it). When not bracketed, send raw UTF-8.
///
/// The payload is always sanitized first (`sanitizedPasteScalars`): clipboard text can come
/// from anywhere, including a server's OSC 52 write, and an embedded `ESC[201~` would
/// otherwise end the paste early and type the rest as live input.
public func bracketedPasteBytes(_ text: String, bracketed: Bool) -> [UInt8] {
    let payload = Array(String(sanitizedPasteScalars(text)).utf8)
    guard bracketed else { return payload }
    let start: [UInt8] = [0x1b, 0x5b, 0x32, 0x30, 0x30, 0x7e]
    let end: [UInt8]   = [0x1b, 0x5b, 0x32, 0x30, 0x31, 0x7e]
    return start + payload + end
}

/// `text` with every control character removed except tab, line feed and carriage return:
/// the rest of C0 (ESC, Ctrl-C, the tmux prefix, NUL...), DEL and C1 (U+0080-U+009F,
/// including the 8-bit CSI U+009B). This is xterm's default paste filtering
/// (`allowPasteControls: false`).
private func sanitizedPasteScalars(_ text: String) -> String.UnicodeScalarView {
    var out = String.UnicodeScalarView()
    for scalar in text.unicodeScalars where isAllowedInPaste(scalar) {
        out.append(scalar)
    }
    return out
}

private func isAllowedInPaste(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x09, 0x0A, 0x0D: return true
    case 0x00...0x1F, 0x7F...0x9F: return false
    default: return true
    }
}
