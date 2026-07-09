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
