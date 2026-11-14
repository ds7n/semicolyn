// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

extension Transport {
    /// Short name for the app-switcher cover.
    public var coverLabel: String {
        switch self {
        case .ssh: return "SSH"
        case .mosh: return "Mosh"
        case .et: return "ET"
        }
    }
}

/// The session on screen, as far as the app-switcher cover is concerned.
public struct CoverSession: Equatable, Sendable {
    public let label: String
    public let hostName: String
    public let transport: Transport

    public init(label: String, hostName: String, transport: Transport) {
        self.label = label
        self.hostName = hostName
        self.transport = transport
    }
}

/// What the app-switcher cover shows: an optional title line and a subtitle.
public struct PrivacyCoverContent: Equatable, Sendable {
    public let title: String?
    public let subtitle: String

    public init(title: String?, subtitle: String) {
        self.title = title
        self.subtitle = subtitle
    }
}

/// The cover text for the innermost open session. Never shows an address: a quick
/// connect session is saved with `label = hostName`, so a label equal to the host name
/// (trimmed, case-insensitive) or an empty label reads "Quick connect".
public func privacyCoverContent(_ session: CoverSession?) -> PrivacyCoverContent {
    guard let session else { return PrivacyCoverContent(title: nil, subtitle: "No session open") }
    let label = session.label.trimmingCharacters(in: .whitespacesAndNewlines)
    let host = session.hostName.trimmingCharacters(in: .whitespacesAndNewlines)
    let isQuickConnect = label.isEmpty || label.caseInsensitiveCompare(host) == .orderedSame
    return PrivacyCoverContent(title: isQuickConnect ? "Quick connect" : label,
                               subtitle: session.transport.coverLabel)
}
