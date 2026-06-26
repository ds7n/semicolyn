// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// The processes whose foreground presence auto-engages Fn (function-keys spec
/// §"Bundled v1 auto-Fn contexts"). Mirrors the promotion-set JSON shape:
/// `{ "<process>": { "autoFn": true|false } }`.
public enum AutoFnCatalog {
    /// `htop`/`top`/`mc` — editors are deliberately excluded.
    public static let bundled: Set<String> = ["htop", "top", "mc"]

    private struct Entry: Decodable { let autoFn: Bool }

    /// Bundled set unioned with a user override (entries with `autoFn:false`
    /// remove a process). Malformed JSON → bundled + a one-time warning.
    public static func load(userOverrideJSON: Data?) -> (processes: Set<String>, warning: String?) {
        guard let data = userOverrideJSON else { return (bundled, nil) }
        do {
            let user = try JSONDecoder().decode([String: Entry].self, from: data)
            var procs = bundled
            for (name, entry) in user {
                if entry.autoFn { procs.insert(name) } else { procs.remove(name) }
            }
            return (procs, nil)
        } catch {
            return (bundled, "Auto-Fn override file is invalid — using defaults.")
        }
    }
}
