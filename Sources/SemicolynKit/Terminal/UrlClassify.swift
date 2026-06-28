// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Tappable-URL schemes recognized by Plan C.
public enum URLKind: Equatable, Sendable { case http, https, ssh }

/// Classify a detected link by scheme; nil for anything outside the allowlist.
public func classifyURL(_ link: String) -> URLKind? {
    let lower = link.lowercased()
    if lower.hasPrefix("https://") { return .https }
    if lower.hasPrefix("http://")  { return .http }
    if lower.hasPrefix("ssh://")   { return .ssh }
    return nil
}

/// Join a URL split across a hard row wrap — only when part1 ends mid-token
/// (no trailing whitespace) and part2 starts at column 0 (no leading whitespace).
public func joinWrappedURL(part1: String, part2: String) -> String? {
    guard let last = part1.last, !last.isWhitespace else { return nil }
    guard let first = part2.first, !first.isWhitespace else { return nil }
    return part1 + part2
}
