// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import os
import SwiftUI

/// TEMPORARY on-device diagnostic sink for the tmux reattach/no-echo investigation.
/// A rolling buffer of timestamped lines, rendered by an on-screen panel and mirrored
/// to `os.Logger` (subsystem `dev.truepositive.semicolyn`, category `debug`) so the
/// same trace is retrievable via Console.app if a Mac is ever attached. Remove this
/// file (and its call sites) once the reattach bug is root-caused.
@MainActor
final class DebugLog: ObservableObject {
    static let shared = DebugLog()

    /// Newest-last rolling buffer; capped so it can't grow unbounded on a long session.
    @Published private(set) var lines: [String] = []
    private let cap = 200
    private let logger = Logger(subsystem: "dev.truepositive.semicolyn", category: "debug")
    /// Monotonic-ish elapsed seconds since first log, so a phone reader sees ordering
    /// without needing wall-clock formatting.
    private var start: TimeInterval?

    private init() {}

    /// Append one diagnostic line (timestamped with elapsed seconds) + mirror to os_log.
    func log(_ message: String) {
        let now = Date().timeIntervalSinceReferenceDate
        if start == nil { start = now }
        let t = now - (start ?? now)
        let line = String(format: "%7.2f  %@", t, message)
        lines.append(line)
        if lines.count > cap { lines.removeFirst(lines.count - cap) }
        logger.debug("\(message, privacy: .public)")
    }

    /// The whole buffer as one string, for copy-to-clipboard.
    var joined: String { lines.joined(separator: "\n") }

    func clear() { lines.removeAll(); start = nil }
}
