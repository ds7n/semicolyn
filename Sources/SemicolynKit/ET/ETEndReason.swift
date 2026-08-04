// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Max scalar length of a sanitized end-reason string.
public let etEndReasonMaxLength = 80

/// Sanitize an ET teardown reason for safe logging / banner display.
///
/// SECURITY: the raw reason may be remote-server-supplied (a handshake-rejection
/// message), so it is UNTRUSTED. This strips ANSI escape sequences (CSI + OSC),
/// C0/C1 control bytes, and angle-bracket markup; collapses whitespace to single
/// spaces so it stays one log line; and truncates to `etEndReasonMaxLength`.
/// `nil`/empty become a fixed default. Callers must route every reason through
/// this before it reaches a log or a UI banner.
public func sanitizeEndReason(_ reason: String?) -> String {
    guard let reason, !reason.isEmpty else { return "connection ended" }

    var out = String.UnicodeScalarView()
    let scalars = Array(reason.unicodeScalars)
    var i = 0
    while i < scalars.count {
        let s = scalars[i]
        // ESC-introduced sequences: CSI (ESC [ ... final 0x40-0x7E) or
        // OSC (ESC ] ... terminated by BEL 0x07 or ST = ESC \).
        if s.value == 0x1B, i + 1 < scalars.count {
            let next = scalars[i + 1]
            if next == "[" {
                i += 2
                while i < scalars.count, !(0x40...0x7E).contains(scalars[i].value) { i += 1 }
                i += 1  // consume the final byte
                continue
            }
            if next == "]" {
                i += 2
                while i < scalars.count {
                    if scalars[i].value == 0x07 { i += 1; break }               // BEL
                    if scalars[i].value == 0x1B, i + 1 < scalars.count,
                       scalars[i + 1] == "\\" { i += 2; break }                  // ST
                    i += 1
                }
                continue
            }
        }
        // Drop angle-bracket markup entirely (whole <...> span). An unterminated
        // '<' drops to end-of-string so trailing markup text cannot leak.
        if s == "<" {
            i += 1
            while i < scalars.count, scalars[i] != ">" { i += 1 }
            if i < scalars.count { i += 1 }   // consume the closing '>'
            continue
        }
        if s == ">" { i += 1; continue }      // stray '>' with no opening tag
        // Collapse any whitespace (incl. newlines) to a single space.
        if s.properties.isWhitespace {
            if out.last != " " { out.append(" ") }
            i += 1; continue
        }
        // Drop C0 (0x00-0x1F) and C1 (0x80-0x9F) control bytes and DEL (0x7F).
        if s.value < 0x20 || s.value == 0x7F || (0x80...0x9F).contains(s.value) {
            i += 1; continue
        }
        out.append(s)
        i += 1
    }

    var result = String(out)
    if result.unicodeScalars.count > etEndReasonMaxLength {
        result = String(String.UnicodeScalarView(result.unicodeScalars.prefix(etEndReasonMaxLength)))
    }
    return result.isEmpty ? "connection ended" : result
}
