// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// The live connection's values that auto-fill the reserved macro placeholders
/// `${host}` / `${user}` / `${port}`. A `nil` field means "not available" (e.g. not
/// connected) and forces a prompt rather than sending an empty value.
public struct MacroConnectionContext: Equatable, Sendable {
    /// Placeholder names that resolve from the connection (never prompted when present).
    public static let reservedNames: Set<String> = ["host", "user", "port"]

    private let values: [String: String]

    public init(host: String? = nil, user: String? = nil, port: String? = nil) {
        var v: [String: String] = [:]
        if let host { v["host"] = host }
        if let user { v["user"] = user }
        if let port { v["port"] = port }
        values = v
    }

    /// The value for a reserved connection name, or `nil` if absent.
    public func value(for name: String) -> String? { values[name] }
}

/// The outcome of resolving a parameterized macro body at fire-time.
public enum MacroResolution: Equatable, Sendable {
    /// Every placeholder filled — the events ready to encode and send.
    case resolved([MacroEvent])
    /// One or more user placeholders still need a value; prompt for these (in body
    /// order, deduped by name). On submit, re-resolve with the entered values.
    case needsInput([MacroPlaceholder])
}

/// Resolves a parameterized macro body. For each `${…}`: connection placeholders
/// (`${host}`/`${user}`/`${port}`) take the live value; any other name takes the
/// remembered-for-this-host value, else its default, else needs a prompt. Returns
/// `.resolved` only when *every* placeholder is filled. A placeholder value expands
/// to one `.char` event per character, interleaved with the body's literal events.
public func resolveMacroBody(_ body: [MacroBodyElement],
                             connection: MacroConnectionContext,
                             remembered: [String: String]) -> MacroResolution {
    func value(_ p: MacroPlaceholder) -> String? {
        if MacroConnectionContext.reservedNames.contains(p.name) {
            return connection.value(for: p.name)
        }
        return remembered[p.name] ?? p.defaultValue
    }

    // Placeholders that still need a prompt, in order, deduped by name.
    var needs: [MacroPlaceholder] = []
    var seen: Set<String> = []
    for case let .placeholder(p) in body where value(p) == nil {
        if seen.insert(p.name).inserted { needs.append(p) }
    }
    if !needs.isEmpty { return .needsInput(needs) }

    var events: [MacroEvent] = []
    for element in body {
        switch element {
        case .event(let e):
            events.append(e)
        case .placeholder(let p):
            for ch in value(p) ?? "" { events.append(MacroEvent(key: .char(ch))) }
        }
    }
    return .resolved(events)
}

/// Per-host memory of the last value entered for each user placeholder, so a
/// parameterized macro pre-fills (or auto-resolves) on the next run against the same
/// host. Persisted by the App; the pure tier just models the data + lookups.
public struct MacroRememberedValues: Equatable, Sendable, Codable {
    private var byHost: [String: [String: String]]

    public init() { byHost = [:] }

    /// The remembered `name → value` map for one host (empty if none).
    public func values(forHost hostID: String) -> [String: String] {
        byHost[hostID] ?? [:]
    }

    /// Records (or overwrites) the value entered for `name` against `hostID`.
    public mutating func remember(_ value: String, name: String, hostID: String) {
        byHost[hostID, default: [:]][name] = value
    }
}
