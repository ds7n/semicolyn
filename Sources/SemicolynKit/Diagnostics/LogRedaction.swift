// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

// Privacy audit P-M3 / P-L4: a diagnostic line marks the values that identify a server or
// account (host names, addresses, user names) and the text a server sent (versions,
// errors, end reasons). The line is stored once with its marks, then rendered per
// destination: in full on the device and over pinned TLS, or with each marked value
// replaced over plain TCP/UDP and in a shareable copy.

/// What a marked value is, which decides its replacement in a shareable rendering.
public enum LogMarkKind: CaseIterable, Sendable {
    /// A host name, label or address: replaced by a stable tag, `host#a3f2`.
    case host
    /// An account name: replaced by a stable tag, `user#a3f2`.
    case user
    /// Text the server sent: replaced by its length, `<server text, 12 chars>`.
    case serverText

    /// Private-use scalars that open and close a value of this kind. They never come
    /// from a keyboard and are removed from the value itself, so a value can't forge or
    /// close a mark.
    var delimiters: (open: Unicode.Scalar, close: Unicode.Scalar) {
        switch self {
        case .host: return ("\u{E000}", "\u{E001}")
        case .user: return ("\u{E002}", "\u{E003}")
        case .serverText: return ("\u{E004}", "\u{E005}")
        }
    }
}

private let logMarkScalars: Set<Unicode.Scalar> = Set(LogMarkKind.allCases.flatMap {
    [$0.delimiters.open, $0.delimiters.close]
})

/// `value` marked as `kind`, for interpolating into a diagnostic line.
public func logMark(_ value: String, _ kind: LogMarkKind) -> String {
    var scalars = String.UnicodeScalarView()
    scalars.append(kind.delimiters.open)
    scalars.append(contentsOf: value.unicodeScalars.filter { !logMarkScalars.contains($0) })
    scalars.append(kind.delimiters.close)
    return String(scalars)
}

/// `host` (a name, label or address) marked for redaction.
public func logHost(_ host: String) -> String { logMark(host, .host) }
/// `user` (an account name) marked for redaction.
public func logUser(_ user: String) -> String { logMark(user, .user) }
/// `text` sent by a server marked for redaction.
public func logServerText(_ text: String) -> String { logMark(text, .serverText) }

/// How a marked line is rendered.
public enum LogRendering: Sendable {
    /// Every value as written (marks removed).
    case full
    /// Hosts and users as tags keyed by `salt`, server text as its length.
    case shareable(salt: Data)
}

/// The stable tag for `value`: the first 4 hex digits of HMAC-SHA256(`salt`, value), so
/// the same host reads the same within one install but can't be looked up from a list of
/// names without the salt. Hosts ignore case (DNS does); users don't (Unix accounts don't).
public func logTag(_ value: String, kind: LogMarkKind, salt: Data) -> String {
    let mac = HMAC<SHA256>.authenticationCode(for: Data((kind == .user ? value : value.lowercased()).utf8),
                                              using: SymmetricKey(data: salt))
    let hex = Data(mac).prefix(2).map { String(format: "%02x", $0) }.joined()
    return "\(kind == .user ? "user" : "host")#\(hex)"
}

/// `line` rendered for `rendering`. A mark that is never closed hides the rest of the
/// line in a shareable rendering, so a cut-off value can't leak.
public func renderLogLine(_ line: String, _ rendering: LogRendering) -> String {
    var out = String.UnicodeScalarView()
    var open: (kind: LogMarkKind, value: String.UnicodeScalarView)?

    func emit(_ kind: LogMarkKind, _ value: String.UnicodeScalarView) {
        switch rendering {
        case .full:
            out.append(contentsOf: value)
        case let .shareable(salt):
            let text = String(value)
            let replacement = kind == .serverText
                ? "<server text, \(text.count) chars>"
                : logTag(text, kind: kind, salt: salt)
            out.append(contentsOf: replacement.unicodeScalars)
        }
    }

    for scalar in line.unicodeScalars {
        if var current = open {
            if scalar == current.kind.delimiters.close {
                emit(current.kind, current.value)
                open = nil
            } else if !logMarkScalars.contains(scalar) {
                current.value.append(scalar)
                open = current
            }
            continue
        }
        if let kind = LogMarkKind.allCases.first(where: { $0.delimiters.open == scalar }) {
            open = (kind, String.UnicodeScalarView())
        } else if !logMarkScalars.contains(scalar) {
            out.append(scalar)
        }
    }
    if let current = open {
        switch rendering {
        case .full: out.append(contentsOf: current.value)
        case .shareable: out.append(contentsOf: "<cut off>".unicodeScalars)
        }
    }
    return String(out)
}

/// The rendering for the remote stream over `transport`: full only over pinned TLS.
public func remoteLogRendering(transport: LogTransport, salt: Data) -> LogRendering {
    remoteLogMaySendContent(transport: transport) ? .full : .shareable(salt: salt)
}

/// One line in the on-device diagnostic buffer.
public struct LogEntry: Equatable, Sendable {
    /// The marked line as recorded, possibly with typed keys in it.
    public var line: String
    /// For a line that carries typed keys, the same line with the keys replaced by their
    /// length; nil for every other line.
    public var withoutTypedKeys: String?

    public init(line: String, withoutTypedKeys: String? = nil) {
        self.line = line
        self.withoutTypedKeys = withoutTypedKeys
    }
}

/// The buffer as text for the "Copy (shareable)" action (privacy audit P-M4 D): typed
/// keys replaced by their length, hosts and users as tags, server text as its length.
public func shareableLogText(_ entries: [LogEntry], salt: Data) -> String {
    entries.map { renderLogLine($0.withoutTypedKeys ?? $0.line, .shareable(salt: salt)) }
        .joined(separator: "\n")
}

/// The buffer as text with everything in it, for the panel and "Copy full".
public func fullLogText(_ entries: [LogEntry]) -> String {
    entries.map { renderLogLine($0.line, .full) }.joined(separator: "\n")
}

/// The UserDefaults key holding the install's tag salt.
public let logTagSaltKey = "diagnostics.tagSalt"

/// The install's salt for `logTag`, created (32 random bytes) on first use, so tags stay
/// the same across launches. Erasing all data gives a new salt.
public func logTagSalt(in defaults: UserDefaults) -> Data {
    if let salt = defaults.data(forKey: logTagSaltKey), salt.count == 32 { return salt }
    let salt = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
    defaults.set(salt, forKey: logTagSaltKey)
    return salt
}
