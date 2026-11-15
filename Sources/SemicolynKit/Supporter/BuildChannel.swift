// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Which kind of build is running, as far as the Supporter set is concerned. The App
/// decides it at build time (a compile condition), never at runtime: App Review runs the
/// submitted build in the same sandbox environment as TestFlight, so runtime detection
/// would show reviewers the TestFlight-only preview.
public enum BuildChannel: Sendable, Equatable, CaseIterable {
    /// A Debug build (Xcode, Simulator).
    case debug
    /// A release build made with the `supporter_preview` flag, for TestFlight only.
    case testFlight
    /// Any other release build, including the one submitted to the App Store.
    case appStore
    /// Not determined. Treated exactly like `appStore` (fail closed).
    case unknown
}

/// Whether Supporter items (themes, icons, the preview toggle) appear at all on this
/// build. Only Debug and preview-flagged TestFlight builds show them.
public func supporterItemsVisible(_ channel: BuildChannel) -> Bool {
    switch channel {
    case .debug, .testFlight: return true
    case .appStore, .unknown: return false
    }
}

/// Whether Supporter items are usable. A purchase always unlocks them (the 1.1 seam);
/// the preview toggle unlocks them only where they are visible.
///
/// - Parameters:
///   - channel: The build channel.
///   - previewOn: The TestFlight-only "Supporter preview" toggle.
///   - purchased: A real Supporter purchase (always false until StoreKit lands).
public func supporterUnlocked(channel: BuildChannel, previewOn: Bool, purchased: Bool) -> Bool {
    if purchased { return true }
    return previewOn && supporterItemsVisible(channel)
}

/// The themes the picker lists: every theme where Supporter items are visible, otherwise
/// only the free ones, so App Store users never see a theme they cannot use.
public func visibleThemes(channel: BuildChannel,
                          catalog: [ThemeDescriptor] = Theme.catalog) -> [ThemeDescriptor] {
    if supporterItemsVisible(channel) { return catalog }
    return catalog.filter { !$0.isPro }
}
