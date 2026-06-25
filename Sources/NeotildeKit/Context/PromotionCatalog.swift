// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Resolves the active promotion registry: bundled defaults overlaid with an
/// optional advanced-user JSON override. A malformed override never crashes and
/// never partially applies — it falls back to bundled entirely and returns a
/// one-time warning string for the settings surface to show.
public enum PromotionCatalog {
    /// JSON shape: `{ "<process>": { "promote": [ {"tap","up?","down?"} ] } }`.
    public static func load(userOverrideJSON: Data?) -> (registry: PromotionRegistry, warning: String?) {
        guard let data = userOverrideJSON else { return (.bundledDefault, nil) }
        do {
            let user = try JSONDecoder().decode([String: PromotionSet].self, from: data)
            return (PromotionRegistry.merge(bundled: .bundledDefault, user: PromotionRegistry(sets: user)), nil)
        } catch {
            return (.bundledDefault, "Keybar promotion override file is invalid — using defaults.")
        }
    }
}
