// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// The Pro-entitlement seam. v1 is a stub backed by `UserDefaults` (default
/// not-active) with a `#if DEBUG` flip so the Simulator pass can exercise the gate
/// and the unlock path without StoreKit. The real StoreKit slice replaces the
/// backing behind this same surface; consumers (`RootView`, the picker, the
/// upgrade screen) do not change.
@MainActor final class ProStore: ObservableObject {
    private static let defaultsKey = "semicolyn.pro.isActive"

    @Published private(set) var isPro: Bool

    init() {
        self.isPro = UserDefaults.standard.bool(forKey: Self.defaultsKey)
    }

    #if DEBUG
    /// Debug-only: flip Pro state to test the gate end-to-end. Removed when real
    /// StoreKit lands.
    func setProForDebug(_ active: Bool) {
        isPro = active
        UserDefaults.standard.set(active, forKey: Self.defaultsKey)
    }
    #endif
}
