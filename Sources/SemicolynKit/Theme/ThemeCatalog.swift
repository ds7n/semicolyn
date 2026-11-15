// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Stable identifier for a theme in the catalog. A thin `String` wrapper (matching
/// `MacroID` / `CustomSlotID`) so the pure tier stays deterministic and the App can
/// persist the raw value directly.
public struct ThemeID: Hashable, Sendable, Codable {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
}

/// A theme family (its dark and light variants) plus the catalog metadata the picker
/// and Pro-gate need. Keeps presentation/commerce concerns off the pure `Theme` token set.
public struct ThemeDescriptor: Equatable, Sendable {
    public let id: ThemeID
    public let displayName: String
    public let isPro: Bool
    public let dark: Theme
    public let light: Theme

    public init(id: ThemeID, displayName: String, isPro: Bool, dark: Theme, light: Theme) {
        self.id = id
        self.displayName = displayName
        self.isPro = isPro
        self.dark = dark
        self.light = light
    }

    /// The variant of this family to render.
    public func theme(for variant: ThemeVariant) -> Theme {
        switch variant {
        case .dark: return dark
        case .light: return light
        }
    }
}

extension Theme {
    /// Ordered theme catalog, the free default first. Single source of truth for
    /// both the picker's order and `Theme.all`.
    public static let catalog: [ThemeDescriptor] = [
        ThemeDescriptor(id: ThemeID("neonMidnight"), displayName: "Neon Midnight",
                        isPro: false, dark: .neonMidnight, light: .neonMidnightLight),
        ThemeDescriptor(id: ThemeID("bellBronze"), displayName: "Bell Bronze",
                        isPro: true, dark: .bellBronze, light: .bellBronzeLight),
        ThemeDescriptor(id: ThemeID("neonCobalt"), displayName: "Neon Cobalt",
                        isPro: true, dark: .neonCobalt, light: .neonCobaltLight),
        ThemeDescriptor(id: ThemeID("glacier"), displayName: "Glacier",
                        isPro: true, dark: .glacier, light: .glacierLight),
    ]

    /// The free default descriptor (first in the catalog).
    public static var defaultDescriptor: ThemeDescriptor { catalog[0] }
}

/// Resolves the descriptor that should actually be applied, enforcing the
/// Pro-gate: a Pro theme requires `isPro`, otherwise it falls back to the free
/// default; an unknown id also falls back. This is the single gate decision, the
/// UI cannot leak a locked theme even with a stale persisted id.
public func resolveDescriptor(
    selectedID: ThemeID,
    isPro: Bool,
    catalog: [ThemeDescriptor] = Theme.catalog
) -> ThemeDescriptor {
    guard let descriptor = catalog.first(where: { $0.id == selectedID }) else {
        return catalog[0]
    }
    if descriptor.isPro && !isPro {
        return catalog[0]
    }
    return descriptor
}

/// The descriptor to render, honoring a live preview. While the theme picker
/// previews a Supporter theme (`previewID`, never persisted) that theme renders even
/// without Pro, so the user can see it; with no preview (or an unknown preview id)
/// this is exactly `resolveDescriptor`, so the stored selection stays Pro-gated.
public func displayedDescriptor(
    selectedID: ThemeID,
    previewID: ThemeID?,
    isPro: Bool,
    catalog: [ThemeDescriptor] = Theme.catalog
) -> ThemeDescriptor {
    if let previewID, let preview = catalog.first(where: { $0.id == previewID }) {
        return preview
    }
    return resolveDescriptor(selectedID: selectedID, isPro: isPro, catalog: catalog)
}

/// Convenience: the resolved `Theme` to apply in `variant` (see `resolveDescriptor`).
public func resolveTheme(
    selectedID: ThemeID,
    isPro: Bool,
    variant: ThemeVariant = .dark,
    catalog: [ThemeDescriptor] = Theme.catalog
) -> Theme {
    resolveDescriptor(selectedID: selectedID, isPro: isPro, catalog: catalog).theme(for: variant)
}
