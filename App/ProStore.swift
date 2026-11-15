// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import SemicolynKit

/// The Supporter-entitlement seam. Until StoreKit lands (1.1) nothing is ever purchased;
/// on Debug and preview-flagged TestFlight builds a persisted "Supporter preview" toggle
/// unlocks the Supporter themes and icons so they can be tried on device. Every other
/// build hides them entirely (`supporterItemsVisible`). The decisions live in
/// SemicolynKit (`supporterUnlocked`); this only stores the toggle. Consumers read
/// `isPro` and do not change when the purchase replaces the preview.
@MainActor final class ProStore: ObservableObject {
    private static let previewKey = "semicolyn.supporter.preview"

    /// How this binary was built (fixed for the process).
    let channel: BuildChannel
    /// The TestFlight-only preview toggle.
    @Published private(set) var previewOn: Bool

    /// Whether Supporter themes and icons are usable.
    var isPro: Bool { supporterUnlocked(channel: channel, previewOn: previewOn, purchased: false) }

    init(channel: BuildChannel = BuildChannelDetector.current) {
        self.channel = channel
        self.previewOn = UserDefaults.standard.bool(forKey: Self.previewKey)
    }

    /// Turns the preview on or off. Turning it off puts back the primary icon if a
    /// Supporter icon was in use.
    func setPreview(_ on: Bool) {
        previewOn = on
        UserDefaults.standard.set(on, forKey: Self.previewKey)
        if !on { enforceIcon() }
    }

    /// Re-reads the stored toggle.
    func reload() {
        previewOn = UserDefaults.standard.bool(forKey: Self.previewKey)
    }

    /// Erase All Data: forget the toggle and drop any Supporter icon.
    func resetToDefault() {
        UserDefaults.standard.removeObject(forKey: Self.previewKey)
        previewOn = false
        enforceIcon()
    }

    private func enforceIcon() {
        let unlocked = isPro
        Task { @MainActor in await AppIconSwitcher.shared.enforce(unlocked: unlocked) }
    }
}
