// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Swift-visible ET connection state, mapped from the C `et_state` enum.
/// `.unknown` carries the raw code so an unexpected value degrades gracefully
/// instead of crashing.
public enum ETConnectionState: Sendable, Equatable {
    case connecting, connected, roaming, disconnected
    case unknown(Int32)
}

/// Map a raw C `et_state` code to `ETConnectionState`. Codes 0-3 match the ABI's
/// enum order (CONNECTING, CONNECTED, ROAMING, DISCONNECTED); any other value
/// becomes `.unknown(raw)` (defensive against a newer/hostile library).
public func mapETState(_ raw: Int32) -> ETConnectionState {
    switch raw {
    case 0: return .connecting
    case 1: return .connected
    case 2: return .roaming
    case 3: return .disconnected
    default: return .unknown(raw)
    }
}
