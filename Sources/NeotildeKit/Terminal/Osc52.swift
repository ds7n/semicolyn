// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Result of gating an OSC 52 clipboard-write request.
public enum Osc52Action: Equatable, Sendable {
    case write([UInt8])
    case drop
}

/// Gate an OSC 52 *write* (SwiftTerm only invokes the clipboard delegate for
/// writes; reads are never echoed back — read = always no-op by construction).
/// Empty payloads drop so a stray sequence can't clear the system clipboard.
public func osc52Action(allow: Bool, content: [UInt8]) -> Osc52Action {
    guard allow, !content.isEmpty else { return .drop }
    return .write(content)
}
