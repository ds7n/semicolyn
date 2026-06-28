// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// A parameter placeholder inside a macro body, written `${name}` or
/// `${name:default}` in a template. Resolved to text at fire-time: connection
/// placeholders (`${host}`/`${user}`/`${port}`) auto-fill from the live session;
/// any other name prompts the user, with the entered value remembered per host and
/// `defaultValue` (when present) pre-filling the prompt. A `nil` `defaultValue` means
/// "no default" (always prompt unless remembered); an empty-string default is an
/// explicit empty value. (keybar-customization spec "Optional placeholders".)
public struct MacroPlaceholder: Equatable, Sendable, Codable {
    public let name: String
    public let defaultValue: String?
    public init(name: String, defaultValue: String? = nil) {
        self.name = name
        self.defaultValue = defaultValue
    }
}

/// One element of a parameterized macro body: either a literal keystroke or a
/// placeholder to be resolved at fire-time. A plain recorded macro is all `.event`s;
/// a template macro may interleave `.placeholder`s.
public enum MacroBodyElement: Equatable, Sendable {
    case event(MacroEvent)
    case placeholder(MacroPlaceholder)
}

extension MacroBodyElement: Codable {
    private enum CodingKeys: String, CodingKey { case kind, event, placeholder }

    /// `kind` discriminator + the payload, mirroring `KeyInput`'s wire form so later
    /// element kinds can be added without disturbing persisted macros.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .event(let e):
            try c.encode("event", forKey: .kind)
            try c.encode(e, forKey: .event)
        case .placeholder(let p):
            try c.encode("placeholder", forKey: .kind)
            try c.encode(p, forKey: .placeholder)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "event":       self = .event(try c.decode(MacroEvent.self, forKey: .event))
        case "placeholder": self = .placeholder(try c.decode(MacroPlaceholder.self, forKey: .placeholder))
        case let k:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: c, debugDescription: "unknown macro body element kind '\(k)'")
        }
    }
}
