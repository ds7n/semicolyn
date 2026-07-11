// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import SemicolynKit

/// UserDefaults keys + defaults for the remote diagnostics stream. All developer-facing,
/// off by default. `LogTransport` (SemicolynKit) is `RawRepresentable` by `String`, so it
/// persists directly via `@AppStorage`.
enum RemoteLogConfig {
    static let enabledKey = "diagnostics.remoteLog.enabled"
    static let hostKey = "diagnostics.remoteLog.host"
    static let portKey = "diagnostics.remoteLog.port"
    static let transportKey = "diagnostics.remoteLog.transport"
    static let keystrokeContentKey = "diagnostics.remoteLog.keystrokeContent"

    static let defaultPort = 6514
    static let defaultTransport: LogTransport = .tls
}
