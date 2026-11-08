// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// How long text the app puts on the clipboard stays there (privacy audit P-M4).
/// The raw value is the lifetime in seconds; `never` (0) leaves it until replaced.
public enum ClipboardClearAfter: Int, CaseIterable, Sendable {
    case never = 0
    case oneMinute = 60
    case fiveMinutes = 300
    case tenMinutes = 600

    /// The picker label.
    public var label: String {
        switch self {
        case .never: return "Never"
        case .oneMinute: return "1 minute"
        case .fiveMinutes: return "5 minutes"
        case .tenMinutes: return "10 minutes"
        }
    }
}

/// Who asked for a clipboard write.
public enum ClipboardSource: Sendable {
    /// The user, through an app control (terminal Copy, Copy public key, ...).
    case app
    /// A remote program, through OSC 52.
    case server
}

/// The pasteboard options for one write: whether it stays off Universal Clipboard and
/// how many seconds until iOS removes it (nil keeps it until replaced).
public struct ClipboardWriteOptions: Equatable, Sendable {
    public let localOnly: Bool
    public let expiresAfter: Int?

    public init(localOnly: Bool, expiresAfter: Int?) {
        self.localOnly = localOnly
        self.expiresAfter = expiresAfter
    }
}

/// Decides the options for a clipboard write (privacy audit P-M4). The user's own copies
/// reach their other devices only when they turned sharing on; a server's OSC 52 copy
/// never does, whatever the setting, since the user didn't choose to copy it. The
/// clear-after timer applies to every write the app makes.
public func clipboardWriteOptions(source: ClipboardSource, shareAcrossDevices: Bool,
                                  clearAfter: ClipboardClearAfter) -> ClipboardWriteOptions {
    let localOnly = source == .server || !shareAcrossDevices
    let expiry = clearAfter == .never ? nil : clearAfter.rawValue
    return ClipboardWriteOptions(localOnly: localOnly, expiresAfter: expiry)
}

/// The app's scene activity, mirrored from SwiftUI's `ScenePhase`.
public enum AppActivity: Sendable {
    case active, inactive, background
}

/// Whether the app-switcher cover should be up (privacy audit P-H1). It goes up as soon
/// as the app stops being active, not only once it's in the background: the app switcher
/// shows an inactive app's live screen before iOS takes the background snapshot.
public func privacyCoverVisible(_ activity: AppActivity, enabled: Bool) -> Bool {
    enabled && activity != .active
}

/// The device-only privacy settings (Settings → Suggestions & Privacy), read from
/// `UserDefaults`. Each `Key` is also the `@AppStorage` key the settings screen binds,
/// with the matching default from `Default`.
public struct PrivacyPreferences: Equatable, Sendable {
    public enum Key {
        public static let hideInAppSwitcher = "privacy.hideInAppSwitcher"
        public static let shareCopiesAcrossDevices = "privacy.shareCopiesAcrossDevices"
        public static let clearCopiedAfter = "privacy.clearCopiedAfterSeconds"
        public static let allowThirdPartyKeyboards = "privacy.allowThirdPartyKeyboards"
    }

    public enum Default {
        public static let hideInAppSwitcher = true
        public static let shareCopiesAcrossDevices = false
        public static let clearCopiedAfter = ClipboardClearAfter.never
        public static let allowThirdPartyKeyboards = false
    }

    public var hideInAppSwitcher: Bool
    public var shareCopiesAcrossDevices: Bool
    public var clearCopiedAfter: ClipboardClearAfter
    public var allowThirdPartyKeyboards: Bool

    /// Reads each setting, using its `Default` when it was never set or holds a value
    /// of the wrong type. An unknown clear-after duration also falls back to `never`.
    public init(defaults: UserDefaults) {
        hideInAppSwitcher = defaults.object(forKey: Key.hideInAppSwitcher) as? Bool
            ?? Default.hideInAppSwitcher
        shareCopiesAcrossDevices = defaults.object(forKey: Key.shareCopiesAcrossDevices) as? Bool
            ?? Default.shareCopiesAcrossDevices
        clearCopiedAfter = (defaults.object(forKey: Key.clearCopiedAfter) as? Int)
            .flatMap(ClipboardClearAfter.init(rawValue:)) ?? Default.clearCopiedAfter
        allowThirdPartyKeyboards = defaults.object(forKey: Key.allowThirdPartyKeyboards) as? Bool
            ?? Default.allowThirdPartyKeyboards
    }
}
