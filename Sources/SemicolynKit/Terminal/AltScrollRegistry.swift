// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// The set of foreground app command-names whose alt-screen binds arrow keys to
/// prompt-history navigation (Ink/Ratatui AI CLIs) and therefore want PgUp/PgDn from an
/// alt-screen scroll gesture instead of arrows. Extensible: adding an app is a one-line
/// change to `bundledDefault` plus a test.
public struct AltScrollRegistry: Sendable {
    /// Apps that bind arrows to history: Claude Code, Gemini CLI, OpenAI Codex, Qwen Code.
    public static let bundledDefault = AltScrollRegistry(
        pageKeyApps: ["claude", "gemini", "codex", "qwen"])

    /// Lowercased process names.
    public let pageKeyApps: Set<String>

    public init(pageKeyApps: Set<String>) {
        self.pageKeyApps = Set(pageKeyApps.map { $0.lowercased() })
    }

    /// EXACT process-name match, case-insensitive. A wrapper like `"claude-wrapper"` does
    /// NOT match (a false match would send Page keys to an app that wanted arrows, which
    /// feels broken). nil/empty/whitespace never matches.
    public func wantsPageKeys(command: String?) -> Bool {
        guard let c = command?.trimmingCharacters(in: .whitespaces).lowercased(),
              !c.isEmpty else { return false }
        return pageKeyApps.contains(c)
    }

    /// Word-boundary, case-insensitive token match against an OSC window title (title mode
    /// only). `"myrepo: claude fix"` matches; `"unclaudely"` does not.
    public func wantsPageKeys(title: String?) -> Bool {
        guard let t = title?.lowercased(), !t.isEmpty else { return false }
        // Split on any non-alphanumeric so `claude:` / `(claude)` tokenize to `claude`.
        let tokens = t.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        return tokens.contains(where: pageKeyApps.contains)
    }
}
