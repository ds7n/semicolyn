// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// How an alt-screen scroll gesture chooses which keys to synthesize. A single
/// user-facing setting (radio); modes are mutually exclusive by construction.
public enum AltScrollMode: String, Sendable, CaseIterable, Codable {
    case off             // always arrows (xterm standard)
    case auto            // arrows, except a registered app in a tmux pane -> page keys [DEFAULT]
    case alwaysPageKeys  // every alt-screen drag -> page keys (breaks less/vim line-scroll)
    case autoPlusTitle   // auto, plus best-effort OSC-title match on non-tmux (brittle)
}

/// The key family an alt-screen drag emits.
public enum AltScrollKeys: Sendable, Equatable { case arrows, pageKeys }

/// Pure decision the App snapshots once at drag `.began`.
/// - paneCommand: tmux `pane_current_command` for this pane; nil on raw/mosh.
/// - windowTitle: OSC 0/2 title; consulted only in `.autoPlusTitle`.
public func altScrollKeys(mode: AltScrollMode,
                          paneCommand: String?,
                          windowTitle: String?,
                          registry: AltScrollRegistry) -> AltScrollKeys {
    switch mode {
    case .off:
        return .arrows
    case .auto:
        return registry.wantsPageKeys(command: paneCommand) ? .pageKeys : .arrows
    case .alwaysPageKeys:
        return .pageKeys
    case .autoPlusTitle:
        if let cmd = paneCommand {
            return registry.wantsPageKeys(command: cmd) ? .pageKeys : .arrows
        }
        return registry.wantsPageKeys(title: windowTitle) ? .pageKeys : .arrows
    }
}
