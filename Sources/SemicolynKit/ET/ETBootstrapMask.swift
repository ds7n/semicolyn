// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// Mask a raw transport bootstrap payload for the `transport` diagnostics log:
/// the credential VALUES are replaced with <id:N>/<key:M>, but the structure
/// (marker, lengths, slash) and any surrounding/trailing content stay visible so
/// a parse malformation (a trailing CR, a status token, a shell banner) is
/// diagnosable WITHOUT logging the live secret. The id/passkey characters are
/// never emitted.
public func maskBootstrapPayload(_ raw: String) -> String {
    let marker = "IDPASSKEY:"
    guard let range = raw.range(of: marker) else {
        let content = sanitizeEndReason(raw)
        return "no-marker len=\(raw.unicodeScalars.count) content=\"\(content)\""
    }
    let leading = String(raw[..<range.lowerBound])
    let after = Array(raw[range.upperBound...].unicodeScalars)
    let total = after.count
    // id window [0..16), slash at 16, key window [17..49) when present.
    let idLen = min(16, after.count)
    let hasSlash = after.count > 16 && after[16] == "/"
    let keyLen = after.count > 17 ? min(32, after.count - 17) : 0
    let slash = hasSlash ? "/" : "?"
    let trailing = after.count > 49 ? reprScalars(Array(after[49...])) : ""
    var out = "\(marker)<id:\(idLen)>\(slash)<key:\(keyLen)>[len=\(total)"
    if !leading.isEmpty { out += " leading=\"\(reprScalars(Array(leading.unicodeScalars)))\"" }
    if !trailing.isEmpty { out += " trailing=\"\(trailing)\"" }
    out += "]"
    return out
}

/// Control-char-safe repr: printable ASCII kept, CR/LF/TAB shown as escapes,
/// other control/non-ASCII as \xNN. Never used on credential windows.
private func reprScalars(_ scalars: [Unicode.Scalar]) -> String {
    var s = ""
    for u in scalars {
        switch u {
        case "\r": s += "\\r"
        case "\n": s += "\\n"
        case "\t": s += "\\t"
        default:
            if u.value >= 0x20 && u.value < 0x7F { s.unicodeScalars.append(u) }
            else { s += String(format: "\\x%02X", u.value) }
        }
    }
    return s
}
