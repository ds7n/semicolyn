// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Validate/normalize an OSC 0/2 window title. Returns the trimmed title, or
/// nil if empty or containing C0/DEL control characters.
public func sanitizeTerminalTitle(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if trimmed.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) {
        return nil
    }
    return trimmed
}
