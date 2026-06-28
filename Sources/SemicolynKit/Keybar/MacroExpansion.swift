// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Encodes a macro body to the raw terminal bytes it should emit, running each
/// event through the same `encodeKey` codec as a live keypress and concatenating
/// the results in order. `applicationCursorKeys` is the live DECCKM state (it
/// only affects arrow events).
public func encodeMacroBody(_ body: [MacroEvent], applicationCursorKeys: Bool) -> [UInt8] {
    body.flatMap { encodeKey($0.key, modifiers: $0.modifiers,
                             applicationCursorKeys: applicationCursorKeys) }
}

extension Macro {
    /// This macro's body encoded to terminal bytes (see `encodeMacroBody`).
    public func encoded(applicationCursorKeys: Bool) -> [UInt8] {
        encodeMacroBody(body, applicationCursorKeys: applicationCursorKeys)
    }
}
