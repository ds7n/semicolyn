// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Bytes to send for pasting `text`. When `bracketed`, wrap the UTF-8 payload in the
/// xterm bracketed-paste markers `ESC[200~` ... `ESC[201~` so the receiving app treats it
/// as pasted text (multi-line stays intact, editors do not auto-indent it, shells do not
/// auto-execute it). When not bracketed, send raw UTF-8.
public func bracketedPasteBytes(_ text: String, bracketed: Bool) -> [UInt8] {
    let payload = Array(text.utf8)
    guard bracketed else { return payload }
    let start: [UInt8] = [0x1b, 0x5b, 0x32, 0x30, 0x30, 0x7e]
    let end: [UInt8]   = [0x1b, 0x5b, 0x32, 0x30, 0x31, 0x7e]
    return start + payload + end
}
