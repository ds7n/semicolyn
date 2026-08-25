// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Distinguishes terminal CSI sequences by their semantic role (editing input vs device response).
public enum CSIKind: Equatable, Sendable {
    /// Keyboard input sequence (arrows, Home, End, Delete, Page Up/Down).
    case editing
    /// Device response or formatting (DA, SGR, cursor position, mouse, DSR).
    case responseOrFormat
    /// Bracketed paste enter sequence (ESC[200~).
    case pasteEnter
    /// Bracketed paste exit sequence (ESC[201~).
    case pasteExit
}

/// Classifies a CSI sequence by its final byte and parameters.
///
/// - Parameters:
///   - finalByte: The final byte of the CSI sequence (e.g., 'A' for arrow up, '~' for Delete).
///   - hadPrivateMarker: True if the sequence contained a private marker (e.g., '?' or '<').
///   - param0: The first parameter, if present (e.g., 3 for Delete, 200 for paste begin).
/// - Returns: The `CSIKind` classification.
public func csiKind(finalByte: UInt8, hadPrivateMarker: Bool, param0: Int?) -> CSIKind {
    // Paste sequences: final ~ with param 200 or 201.
    if finalByte == UInt8(ascii: "~") {
        if param0 == 200 {
            return .pasteEnter
        }
        if param0 == 201 {
            return .pasteExit
        }
        // Tilde with editing-related params: 1 (Home), 3 (Delete), 5 (Page Up), 6 (Page Down).
        if let p = param0, [1, 3, 5, 6].contains(p) {
            return .editing
        }
        // Tilde with other params is a response (e.g., F1-F4, other keys).
        return .responseOrFormat
    }

    // Editing: arrows and cursor keys (A, B, C, D, H, F) without private marker.
    if !hadPrivateMarker && [UInt8(ascii: "A"), UInt8(ascii: "B"), UInt8(ascii: "C"),
                              UInt8(ascii: "D"), UInt8(ascii: "H"), UInt8(ascii: "F")].contains(finalByte) {
        return .editing
    }

    // Everything else is a response or formatting sequence.
    return .responseOrFormat
}
