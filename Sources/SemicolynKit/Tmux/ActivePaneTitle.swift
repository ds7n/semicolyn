// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Decide whether a freshly-emitted OSC 0/2 title from `source` should become the
/// window's title: only the active pane's title is published, so a background pane
/// can't clobber what the user is looking at. Returns the title to publish, or nil
/// to drop it.
public func titleToPublish(source: PaneID, active: PaneID?, title: String) -> String? {
    source == active ? title : nil
}

/// The title to show after the active pane changes (e.g. `⌘]` next-pane): the newly
/// active pane's last-known title, or nil when none has been seen (clears the stale
/// previous-pane title until the new pane emits one).
public func titleOnActiveChange(active: PaneID?, lastTitles: [PaneID: String]) -> String? {
    guard let active else { return nil }
    return lastTitles[active]
}
