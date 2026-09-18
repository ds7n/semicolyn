// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Parse a `tmux show -gv prefix` value ("C-b", "C-a", ...) into the control byte
/// it emits. Only `C-<letter>` is supported (Phase 1); everything else (None, meta,
/// multi-key, garbage) returns nil so the caller falls back to a default, never a
/// wrong byte.
public func parseTmuxPrefix(_ raw: String) -> UInt8? {
    let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard s.count == 3 else { return nil }              // "C-x" exactly
    let chars = Array(s)
    guard chars[0] == "C" || chars[0] == "c", chars[1] == "-" else { return nil }
    let letter = Character(chars[2].lowercased())
    guard let a = letter.asciiValue, a >= 0x61, a <= 0x7a else { return nil }  // a..z
    return a - 0x60                                      // 'a'(0x61) -> 0x01 ... 'z'(0x7a) -> 0x1a
}

/// The tmux prefix BYTE gestures should send, resolved by precedence:
///   manual `override` (user-set) > auto-`learned` (per-host) > this-session `discovered`
///   > `fallback` (C-b default).
///
/// `override` and `learned` are raw tmux strings ("C-a"); each is parsed and used only if
/// it parses, so a typo/garbage value is IGNORED and resolution falls through to the next
/// source rather than silently sending a wrong byte (which would break gestures). This is
/// the single source of truth for the byte, so a resumed session (where in-band discovery
/// cannot run) still gets the right prefix from the host's learned value.
public func resolveTmuxPrefixByte(override: String?, learned: String?,
                                  discovered: UInt8?, fallback: UInt8) -> UInt8 {
    if let o = override, let b = parseTmuxPrefix(o) { return b }
    if let l = learned, let b = parseTmuxPrefix(l) { return b }
    if let d = discovered { return d }
    return fallback
}

/// Extract `<value>` from `SEMICOLYN_PREFIX=<value>` in accumulated launch output.
///
/// Uses the LAST occurrence of the marker: on Mosh/ET the launch command is typed into
/// an interactive PTY that ECHOES the `printf 'SEMICOLYN_PREFIX=%s\r' ...` source line, so
/// the first `SEMICOLYN_PREFIX=` match is the unparseable format string; the real executed
/// output always follows. If that last occurrence is a truncated partial chunk (buffer ends
/// before the value completes) the value is empty and we return nil, so the idempotent caller
/// retries on the next tick once more bytes arrive.
public func parseSemicolynPrefixSentinel(_ output: String) -> String? {
    guard let r = output.range(of: "SEMICOLYN_PREFIX=", options: .backwards) else { return nil }
    let rest = output[r.upperBound...]
    // value runs until the first CR/LF; trim trailing spaces.
    let value = rest.prefix { $0 != "\r" && $0 != "\n" }
    let trimmed = value.trimmingCharacters(in: .whitespaces)
    return trimmed.isEmpty ? nil : trimmed
}

/// `<prefix>` then a single key: `[prefix, ascii(key)]`.
public func prefixKeySequence(prefix: UInt8, key: Character) -> [UInt8] {
    guard let a = key.asciiValue else { return [prefix] }
    return [prefix, a]
}

/// The tmux command prompt: `<prefix> : <command> Enter`.
public func prefixCommandSequence(prefix: UInt8, command: String) -> [UInt8] {
    var bytes: [UInt8] = [prefix, 0x3a]     // prefix, ':'
    bytes += Array(command.utf8)
    bytes.append(0x0d)                       // Enter (CR)
    return bytes
}
