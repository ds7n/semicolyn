// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Result of gating an OSC 52 clipboard-write request.
public enum Osc52Action: Equatable, Sendable {
    case write([UInt8])
    case drop
    /// Allowed, but larger than `osc52MaxBytes`: refused, and the user is told.
    case tooLarge(bytes: Int)
}

/// The largest OSC 52 write accepted (1 MiB of decoded payload). Copying from tmux or vim
/// stays far below it; anything bigger is refused rather than silently replacing the
/// clipboard with a huge blob (security audit M1).
public let osc52MaxBytes = 1 << 20

/// Gate an OSC 52 *write* (SwiftTerm only invokes the clipboard delegate for
/// writes; reads are never echoed back, read = always no-op by construction).
/// Empty payloads drop so a stray sequence can't clear the system clipboard.
public func osc52Action(allow: Bool, content: [UInt8]) -> Osc52Action {
    guard allow, !content.isEmpty else { return .drop }
    guard content.count <= osc52MaxBytes else { return .tooLarge(bytes: content.count) }
    return .write(content)
}

/// The brief notice shown when a server writes the clipboard, so a write is never
/// silent (security audit M1). `nil` for `.drop` (a disabled or empty write stays quiet).
public func osc52Notice(_ action: Osc52Action) -> String? {
    switch action {
    case .drop:
        return nil
    case .write(let bytes):
        let n = String(decoding: bytes, as: UTF8.self).count
        return "Server copied \(n) \(n == 1 ? "character" : "characters") to the clipboard"
    case .tooLarge(let bytes):
        let mb = Double(bytes) / Double(1 << 20)
        return String(format: "Blocked a %.1f MB clipboard copy from the server (limit 1 MB)", mb)
    }
}
