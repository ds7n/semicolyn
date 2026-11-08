// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import UIKit
import SemicolynKit

/// Puts `text` on the clipboard with the options the privacy settings call for (privacy
/// audit P-M4): local-only unless the user shares copies with their other devices (a
/// server's OSC 52 copy is always local-only), and an expiry when "Clear copied text
/// after" is set. Every copy the app itself performs goes through here; text the user
/// selects and copies with the system menu in a Settings screen (public keys,
/// fingerprints) uses the system clipboard as usual.
@MainActor
func copyToClipboard(_ text: String, source: ClipboardSource) {
    let prefs = PrivacyPreferences(defaults: .standard)
    let opts = clipboardWriteOptions(source: source,
                                     shareAcrossDevices: prefs.shareCopiesAcrossDevices,
                                     clearAfter: prefs.clearCopiedAfter)
    var options: [UIPasteboard.OptionsKey: Any] = [.localOnly: opts.localOnly]
    if let seconds = opts.expiresAfter {
        options[.expirationDate] = Date().addingTimeInterval(TimeInterval(seconds))
    }
    UIPasteboard.general.setItems([["public.utf8-plain-text": text]], options: options)
}
