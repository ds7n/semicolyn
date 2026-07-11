// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Decide how a keystroke event is rendered in the diagnostic trace.
///
/// - `logContent == false` (default): structural only — the event verb + length, no
///   characters. Diagnoses key-path behavior (e.g. backspace repeat) without exposing
///   what was typed.
/// - `logContent == true` on a password/prompt line: a VISIBLE redaction marker with the
///   length and reason — never the content, and never a silent drop (the trace still
///   shows a password line happened).
/// - `logContent == true` otherwise: the actual content.
public func keystrokeLogDecision(event: String, content: String,
                                 logContent: Bool, isPasswordLine: Bool) -> String {
    let len = content.count
    guard logContent else { return "\(event)(len=\(len))" }
    if isPasswordLine { return "\(event)(REDACTED len=\(len) reason=password-line)" }
    return "\(event)(\"\(content)\")"
}
