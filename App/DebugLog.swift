// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import os

/// On-device diagnostic sink. A rolling buffer of timestamped lines rendered by the
/// on-screen panel (Settings → Diagnostics) and mirrored to `os.Logger` (subsystem
/// `dev.truepositive.semicolyn`, category `debug`).
///
/// SACRED-PATH SAFE: `log` takes an `@autoclosure`, and when diagnostics is disabled
/// (the default) it returns immediately WITHOUT evaluating the message — so a
/// `DebugLog.shared.log("input[\(n)B] → …")` on the keystroke path costs nothing (no
/// string built, no `Date()`, no allocation, no publish) unless the user turned
/// diagnostics on. The buffer is deliberately NOT `@Published`: appends must not fire
/// SwiftUI invalidation per keystroke. The panel observes `revision` (bumped at most
/// on a timer) to refresh.
@MainActor
final class DebugLog: ObservableObject {
    static let shared = DebugLog()

    /// Master switch, mirrored from `@AppStorage(DiagnosticsSettingsView.showDebugPanelKey)`.
    /// When false, `log` is a no-op and its `@autoclosure` message is never evaluated.
    var enabled = UserDefaults.standard.bool(forKey: DiagnosticsSettingsView.showDebugPanelKey)

    /// Newest-last rolling buffer; capped so it can't grow unbounded. Plain (not
    /// `@Published`) so appends never invalidate SwiftUI. The panel reads it on refresh.
    private(set) var lines: [String] = []
    /// Bumped by `refresh()` (panel-driven, throttled) so the view redraws without a
    /// per-append publish.
    @Published private(set) var revision = 0

    private let cap = 200
    private let logger = Logger(subsystem: "dev.truepositive.semicolyn", category: "debug")
    private var start: TimeInterval?

    private init() {}

    /// Record one diagnostic line — but ONLY when enabled. The message is an
    /// autoclosure, so when disabled nothing is evaluated (zero sacred-path cost).
    func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        let now = Date().timeIntervalSinceReferenceDate
        if start == nil { start = now }
        let t = now - (start ?? now)
        let line = String(format: "%7.2f  %@", t, message())
        lines.append(line)
        if lines.count > cap { lines.removeFirst(lines.count - cap) }
        logger.debug("\(line, privacy: .public)")
    }

    /// Panel-driven refresh: publish a redraw for the current buffer. Called on a
    /// timer by the panel, so recording never publishes per-append.
    func refresh() { revision &+= 1 }

    /// The whole buffer as one string, for copy-to-clipboard.
    var joined: String { lines.joined(separator: "\n") }

    func clear() { lines.removeAll(); start = nil; revision &+= 1 }
}
