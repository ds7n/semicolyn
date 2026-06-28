// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Stable identifier for a macro in the keybar library. A thin `String` wrapper
/// (rather than `UUID`) so the pure tier stays deterministic-testable and the
/// App can mint values however it likes (typically a UUID string).
public struct MacroID: Hashable, Sendable, Codable {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
}

/// One input event in a macro body: a logical key plus the modifiers held with
/// it. Reuses the 4a keystroke codec types so a macro encodes through the exact
/// same `encodeKey` path as a live keypress.
public struct MacroEvent: Equatable, Sendable, Codable {
    public var key: KeyInput
    public var modifiers: KeyModifiers
    public init(key: KeyInput, modifiers: KeyModifiers = KeyModifiers()) {
        self.key = key
        self.modifiers = modifiers
    }
}

/// A recorded or templated sequence of input events with a display name. The
/// library's authoritative unit; keybar slots and custom-slot bindings reference
/// a macro by `id`. (keybar-customization spec "Macro metadata"; v1 omits the
/// optional placeholders / context filter — deferred to a v2 follow-up.)
public struct Macro: Equatable, Sendable, Codable, Identifiable {
    public let id: MacroID
    public var name: String
    /// The plain (placeholder-free) keystrokes. Authoritative for plain macros and the
    /// static skeleton for parameterized ones; what existing display/encode paths read.
    public var body: [MacroEvent]
    /// Optional `${…}`-parameterized template, resolved at fire-time via
    /// `resolveMacroBody`. `nil` for plain recorded/parsed macros. Persisted as an
    /// optional key, so older macro records (no key) decode as plain. (4d-2)
    public var parameterizedBody: [MacroBodyElement]?

    public init(id: MacroID, name: String, body: [MacroEvent]) {
        self.id = id
        self.name = name
        self.body = body
        self.parameterizedBody = nil
    }

    /// A parameterized macro: `parameterizedBody` is authoritative at fire-time; `body`
    /// is derived as its static (placeholder-free) keystrokes for display/back-compat.
    public init(id: MacroID, name: String, parameterizedBody: [MacroBodyElement]) {
        self.id = id
        self.name = name
        self.body = parameterizedBody.compactMap { element in
            if case .event(let e) = element { return e }
            return nil
        }
        self.parameterizedBody = parameterizedBody
    }

    /// Whether this macro carries `${…}` placeholders to resolve at fire-time.
    public var isParameterized: Bool { parameterizedBody != nil }

    /// The body to hand to `resolveMacroBody` at fire-time: the parameterized template
    /// if present, else the plain events wrapped as elements (which resolve trivially).
    public var resolvableBody: [MacroBodyElement] {
        parameterizedBody ?? body.map(MacroBodyElement.event)
    }
}

extension KeyInput: Codable {
    private enum CodingKeys: String, CodingKey { case kind, value }

    /// Stable, forward-safe wire form mirroring `KeybarSlot`: a `kind`
    /// discriminator plus a `value` for the payload-carrying cases
    /// (`char`/`arrow`/`function`). Keeps persisted macros readable and lets
    /// later slices add keys without disturbing the schema.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .escape:    try c.encode("escape", forKey: .kind)
        case .tab:       try c.encode("tab", forKey: .kind)
        case .enter:     try c.encode("enter", forKey: .kind)
        case .backspace: try c.encode("backspace", forKey: .kind)
        case .char(let ch):
            try c.encode("char", forKey: .kind)
            try c.encode(String(ch), forKey: .value)
        case .arrow(let d):
            try c.encode("arrow", forKey: .kind)
            try c.encode(d.rawValue, forKey: .value)
        case .function(let n):
            try c.encode("function", forKey: .kind)
            try c.encode(n, forKey: .value)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "escape":    self = .escape
        case "tab":       self = .tab
        case "enter":     self = .enter
        case "backspace": self = .backspace
        case "char":
            let s = try c.decode(String.self, forKey: .value)
            guard let ch = s.first, s.count == 1 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .value, in: c,
                    debugDescription: "char value must be a single character, got '\(s)'")
            }
            self = .char(ch)
        case "arrow":
            let s = try c.decode(String.self, forKey: .value)
            guard let d = ArrowDirection(rawValue: s) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .value, in: c, debugDescription: "unknown arrow direction '\(s)'")
            }
            self = .arrow(d)
        case "function":
            self = .function(try c.decode(Int.self, forKey: .value))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: c, debugDescription: "unknown key input kind '\(kind)'")
        }
    }
}
