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

    /// MASTER logging switch, mirrored from
    /// `@AppStorage(DiagnosticsSettingsView.loggingEnabledKey)`. When false, `log` is a
    /// no-op and its `@autoclosure` message is never evaluated (zero sacred-path cost).
    /// This is INDEPENDENT of where logs go: the on-screen panel and the remote stream are
    /// separate destination toggles. Previously the on-screen-panel switch doubled as the
    /// master gate, so remote streaming silently required the panel to be on (the "zero
    /// .gesture lines" trap, build 44) — now decoupled.
    var enabled = UserDefaults.standard.bool(forKey: DiagnosticsSettingsView.loggingEnabledKey)

    /// Newest-last rolling buffer; capped so it can't grow unbounded. Plain (not
    /// `@Published`) so appends never invalidate SwiftUI. The panel reads it on refresh.
    private(set) var lines: [String] = []
    /// Bumped by `refresh()` (panel-driven, throttled) so the view redraws without a
    /// per-append publish.
    @Published private(set) var revision = 0

    private let cap = 200
    private let logger = Logger(subsystem: "dev.truepositive.semicolyn", category: "debug")
    private var start: TimeInterval?
    /// Optional off-device stream. Set from Diagnostics when remote logging is enabled;
    /// nil disables forwarding. Each recorded line is also sent here.
    private var remote: RemoteLogSink?

    private init() {}

    /// Categories currently enabled (cached; refreshed by `refreshEnabledCategories`).
    /// Seeded from each category's `@AppStorage` value, falling back to its default.
    private var enabledCategories: Set<LogCategory> = {
        var set = Set<LogCategory>()
        for c in LogCategory.allCases {
            let key = c.storageKey
            let on = UserDefaults.standard.object(forKey: key) as? Bool ?? c.defaultOn
            if on { set.insert(c) }
        }
        return set
    }()

    /// Re-read every category toggle from UserDefaults. Call when the Diagnostics
    /// category settings change (e.g. `DiagnosticsSettingsView.onAppear` / onChange).
    func refreshEnabledCategories() {
        var set = Set<LogCategory>()
        for c in LogCategory.allCases {
            let on = UserDefaults.standard.object(forKey: c.storageKey) as? Bool ?? c.defaultOn
            if on { set.insert(c) }
        }
        enabledCategories = set
    }

    /// Record one diagnostic line in `category` — ONLY when diagnostics is enabled AND the
    /// category is on. The message is an autoclosure: nothing is evaluated when gated out
    /// (zero sacred-path cost). `category` defaults to `.lifecycle` for legacy call sites.
    func log(_ category: LogCategory = .lifecycle, _ message: @autoclosure () -> String) {
        guard enabled, enabledCategories.contains(category) else { return }
        let now = Date().timeIntervalSinceReferenceDate
        if start == nil { start = now }
        let t = now - (start ?? now)
        let line = String(format: "%7.2f  %@", t, message())
        lines.append(line)
        if lines.count > cap { lines.removeFirst(lines.count - cap) }
        logger.debug("\(line, privacy: .public)")
        remote?.send(line)
    }

    func setRemote(_ sink: RemoteLogSink?) {
        remote?.stop()
        remote = sink
    }

    /// Configure the master gate + remote sink from persisted settings AT LAUNCH, so
    /// remote streaming works from a cold start without first visiting the Diagnostics
    /// screen (previously the sink was only attached in `DiagnosticsSettingsView.onAppear`,
    /// so a session connected before opening Settings streamed nothing — part of the
    /// build-44 empty-log trap). Idempotent; safe to call once from app `init`.
    func configureFromDefaults() {
        let d = UserDefaults.standard
        enabled = d.bool(forKey: DiagnosticsSettingsView.loggingEnabledKey)
        refreshEnabledCategories()
        let remoteOn = d.bool(forKey: RemoteLogConfig.enabledKey)
        let host = d.string(forKey: RemoteLogConfig.hostKey) ?? ""
        if remoteOn, !host.isEmpty {
            let port = d.object(forKey: RemoteLogConfig.portKey) as? Int ?? RemoteLogConfig.defaultPort
            let transport = (d.string(forKey: RemoteLogConfig.transportKey))
                .flatMap(LogTransport.init(rawValue:)) ?? RemoteLogConfig.defaultTransport
            setRemote(RemoteLogSink(host: host, port: port, transport: transport))
        }
        logConfig(reason: "launch")
    }

    /// Emit a one-line snapshot of the effective logging configuration, BYPASSING the
    /// master gate and category filter so it records even when logging is off. Lets a
    /// device trace confirm *why* it's empty ("logging=OFF" explains zero lines) instead
    /// of leaving us guessing (build 44: banner streamed but no gesture lines). Called on
    /// session connect and when the config changes.
    func logConfig(reason: String) {
        let cats = LogCategory.allCases
            .filter { enabledCategories.contains($0) }
            .map { "\($0)" }
            .sorted()
            .joined(separator: ",")
        let line = "logConfig(\(reason)): logging=\(enabled ? "ON" : "OFF") "
            + "remote=\(remote != nil ? "ON" : "off") categories=[\(cats)]"
        // Record to the on-screen buffer AND the remote stream directly, ungated.
        let now = Date().timeIntervalSinceReferenceDate
        if start == nil { start = now }
        let stamped = String(format: "%7.2f  %@", now - (start ?? now), line)
        lines.append(stamped)
        if lines.count > cap { lines.removeFirst(lines.count - cap) }
        logger.debug("\(stamped, privacy: .public)")
        remote?.send(stamped)
    }

    /// Panel-driven refresh: publish a redraw for the current buffer. Called on a
    /// timer by the panel, so recording never publishes per-append.
    func refresh() { revision &+= 1 }

    /// The whole buffer as one string, for copy-to-clipboard.
    var joined: String { lines.joined(separator: "\n") }

    func clear() { lines.removeAll(); start = nil; revision &+= 1 }
}
