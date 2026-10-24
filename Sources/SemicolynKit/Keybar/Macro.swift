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
/// a macro by `id`. (keybar-customization spec "Macro metadata".)
///
/// Macros have no parameters: `${...}` is plain text. Older builds could store a
/// `parameterizedBody` (literal events interleaved with `${name}` /
/// `${name:default}` placeholders) next to a placeholder-free `body`. Decoding
/// such a record folds the placeholders back into `body` as the literal text the
/// user typed, so the macro sends exactly that text; encoding writes only `body`.
public struct Macro: Equatable, Sendable, Codable, Identifiable {
    public let id: MacroID
    public var name: String
    /// The keystrokes this macro sends, in order.
    public var body: [MacroEvent]

    public init(id: MacroID, name: String, body: [MacroEvent]) {
        self.id = id
        self.name = name
        self.body = body
    }

    private enum CodingKeys: String, CodingKey { case id, name, body, parameterizedBody }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(MacroID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        if let legacy = try c.decodeIfPresent([LegacyMacroBodyElement].self, forKey: .parameterizedBody) {
            // The legacy template is authoritative: its `body` dropped the placeholders.
            body = legacy.flatMap(\.literalEvents)
        } else {
            body = try c.decode([MacroEvent].self, forKey: .body)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(body, forKey: .body)
    }
}

/// Decode-only reader for one element of a legacy `parameterizedBody`: a literal
/// event, or a `${name}` / `${name:default}` placeholder that is now plain text.
private enum LegacyMacroBodyElement: Decodable {
    case event(MacroEvent)
    case placeholder(name: String, defaultValue: String?)

    private enum CodingKeys: String, CodingKey { case kind, event, placeholder }
    private enum PlaceholderKeys: String, CodingKey { case name, defaultValue }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "event":
            self = .event(try c.decode(MacroEvent.self, forKey: .event))
        case "placeholder":
            let p = try c.nestedContainer(keyedBy: PlaceholderKeys.self, forKey: .placeholder)
            self = .placeholder(name: try p.decode(String.self, forKey: .name),
                                defaultValue: try p.decodeIfPresent(String.self, forKey: .defaultValue))
        case let k:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: c, debugDescription: "unknown macro body element kind '\(k)'")
        }
    }

    /// The events this element sends now: the event itself, or the placeholder's
    /// source text (`${name}` or `${name:default}`) as one character each.
    var literalEvents: [MacroEvent] {
        switch self {
        case .event(let e):
            return [e]
        case .placeholder(let name, let defaultValue):
            let text = "${" + name + (defaultValue.map { ":" + $0 } ?? "") + "}"
            return text.map { MacroEvent(key: .char($0)) }
        }
    }
}
