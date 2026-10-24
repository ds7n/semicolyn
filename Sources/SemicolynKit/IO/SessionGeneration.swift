// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Which connection a late callback belongs to. The view model advances it on every
/// teardown; a transport callback (SSH output or exit, Mosh `onEnd`) captures the
/// value current when its session opened and acts only while `isCurrent` holds, so
/// a session that a Reconnect already replaced can never touch the new one.
public struct SessionGeneration: Equatable, Sendable {
    public private(set) var value: UInt64 = 0

    public init() {}

    /// Start a new generation (teardown): every earlier capture becomes stale.
    public mutating func advance() {
        value &+= 1
    }

    /// Whether a callback that captured `captured` is from the live session.
    public func isCurrent(_ captured: UInt64) -> Bool {
        captured == value
    }
}
