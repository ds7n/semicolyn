// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// One choosable app icon. The asset names must match what
/// `scripts/render-app-icons.py` writes into `App/Assets.xcassets`.
public struct AppIconVariant: Sendable, Equatable, Identifiable {
    /// Stable id, e.g. `"bronze-light"`.
    public let id: String
    /// Name shown under the thumbnail, e.g. `"Bronze Light"`.
    public let displayName: String
    /// The name passed to `setAlternateIconName`; nil for the primary icon.
    public let alternateIconName: String?
    /// The imageset the picker draws as the thumbnail.
    public let previewAssetName: String
    /// Part of the Supporter set (needs `supporterUnlocked`).
    public let isSupporter: Bool

    public init(id: String, displayName: String, alternateIconName: String?,
                previewAssetName: String, isSupporter: Bool) {
        self.id = id
        self.displayName = displayName
        self.alternateIconName = alternateIconName
        self.previewAssetName = previewAssetName
        self.isSupporter = isSupporter
    }
}

extension AppIconVariant {
    /// Builds a row from its PascalCase asset stem; `primary` has no alternate name.
    private static func row(_ id: String, _ name: String, _ stem: String,
                            supporter: Bool, primary: Bool = false) -> AppIconVariant {
        AppIconVariant(id: id, displayName: name,
                       alternateIconName: primary ? nil : "AppIcon-\(stem)",
                       previewAssetName: "IconPreview-\(stem)", isSupporter: supporter)
    }

    /// Picker order, the primary icon first.
    public static let catalog: [AppIconVariant] = [
        row("midnight-dark", "Midnight Dark", "MidnightDark", supporter: false, primary: true),
        row("midnight-light", "Midnight Light", "MidnightLight", supporter: false),
        row("bronze-dark", "Bronze Dark", "BronzeDark", supporter: true),
        row("bronze-light", "Bronze Light", "BronzeLight", supporter: true),
        row("cobalt-dark", "Cobalt Dark", "CobaltDark", supporter: true),
        row("cobalt-light", "Cobalt Light", "CobaltLight", supporter: true),
        row("glacier-dark", "Glacier Dark", "GlacierDark", supporter: true),
        row("glacier-light", "Glacier Light", "GlacierLight", supporter: true),
    ]

    /// The primary icon (first in the catalog).
    public static var defaultIcon: AppIconVariant { catalog[0] }
}

/// The icons the picker lists: all of them where Supporter items are visible, otherwise
/// only the free ones.
public func visibleIcons(channel: BuildChannel,
                         catalog: [AppIconVariant] = AppIconVariant.catalog) -> [AppIconVariant] {
    if supporterItemsVisible(channel) { return catalog }
    return catalog.filter { !$0.isSupporter }
}

/// The icon that should be in use, given the alternate name iOS reports. A locked
/// Supporter icon, or a name the catalog no longer has, falls back to the primary icon.
public func resolveIcon(currentAlternateName: String?, unlocked: Bool,
                        catalog: [AppIconVariant] = AppIconVariant.catalog) -> AppIconVariant {
    let primary = catalog[0]
    guard let name = currentAlternateName,
          let icon = catalog.first(where: { $0.alternateIconName == name }) else { return primary }
    if icon.isSupporter && !unlocked { return primary }
    return icon
}
