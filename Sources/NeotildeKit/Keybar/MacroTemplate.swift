// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Why a macro template string failed to parse. Each case names the specific
/// malformed class so the editor can show a precise message.
public enum MacroTemplateError: Error, Equatable, Sendable {
    /// A `{` with no closing `}` (e.g. `"{Ctrl+R"`).
    case unterminatedPlaceholder
    /// An empty `{}` placeholder.
    case emptyPlaceholder
    /// A `}` with no matching `{` (e.g. `"a}b"`; use `}}` for a literal brace).
    case unexpectedCloseBrace
    /// A modifier followed by nothing (e.g. `"{Ctrl+}"`).
    case danglingModifier
    /// A modifier token that isn't Ctrl/Alt/Option/Shift.
    case unknownModifier(String)
    /// A key token that names no known key (e.g. `"{Frobnicate}"`, `"{F13}"`).
    case unknownKey(String)
}

/// Parses a macro *template* string into a `[MacroEvent]` body. Literal text
/// becomes `.char` events; `{…}` placeholders name special keys or chords:
///
///   - Named keys: `{Enter}` `{Tab}` `{Esc}`/`{Escape}` `{Backspace}` `{Space}`
///     `{Up}` `{Down}` `{Left}` `{Right}` `{F1}`…`{F12}`.
///   - Chords: `{Ctrl+R}`, `{Ctrl+Shift+K}`, `{Alt+X}` — one or more modifiers
///     (Ctrl/Control, Alt/Option/Opt, Shift) joined to a final key by `+`.
///   - Literal braces: `{{` → `{`, `}}` → `}`.
///
/// Names are case-insensitive. (keybar-customization spec "Template mode".)
public enum MacroTemplate {
    public static func parse(_ template: String) throws -> [MacroEvent] {
        var events: [MacroEvent] = []
        let chars = Array(template)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "{" {
                if i + 1 < chars.count, chars[i + 1] == "{" {   // escaped "{{"
                    events.append(MacroEvent(key: .char("{")))
                    i += 2
                    continue
                }
                guard let close = chars[(i + 1)...].firstIndex(of: "}") else {
                    throw MacroTemplateError.unterminatedPlaceholder
                }
                let inner = String(chars[(i + 1)..<close])
                events.append(try parsePlaceholder(inner))
                i = close + 1
            } else if c == "}" {
                if i + 1 < chars.count, chars[i + 1] == "}" {   // escaped "}}"
                    events.append(MacroEvent(key: .char("}")))
                    i += 2
                    continue
                }
                throw MacroTemplateError.unexpectedCloseBrace
            } else {
                events.append(MacroEvent(key: .char(c)))
                i += 1
            }
        }
        return events
    }

    /// Parses the text inside one `{…}` into a single modifier-bearing event.
    private static func parsePlaceholder(_ inner: String) throws -> MacroEvent {
        guard !inner.isEmpty else { throw MacroTemplateError.emptyPlaceholder }
        let parts = inner.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        let keyToken = parts[parts.count - 1]
        guard !keyToken.isEmpty else { throw MacroTemplateError.danglingModifier }

        var modifiers = KeyModifiers()
        for raw in parts.dropLast() {
            switch raw.lowercased() {
            case "ctrl", "control":   modifiers.control = true
            case "alt", "option", "opt": modifiers.option = true
            case "shift":             modifiers.shift = true
            case "":                  throw MacroTemplateError.danglingModifier
            default:                  throw MacroTemplateError.unknownModifier(raw)
            }
        }
        return MacroEvent(key: try parseKeyToken(keyToken), modifiers: modifiers)
    }

    /// Resolves the final token of a placeholder to a `KeyInput`. A single
    /// character is a literal `char`; anything else must be a known key name.
    private static func parseKeyToken(_ token: String) throws -> KeyInput {
        if token.count == 1 { return .char(token.first!) }
        switch token.lowercased() {
        case "enter", "return": return .enter
        case "tab":             return .tab
        case "esc", "escape":   return .escape
        case "backspace", "bs": return .backspace
        case "space":           return .char(" ")
        case "up":              return .arrow(.up)
        case "down":            return .arrow(.down)
        case "left":            return .arrow(.left)
        case "right":           return .arrow(.right)
        default:
            if let n = fKeyNumber(token), (1...12).contains(n) { return .function(n) }
            throw MacroTemplateError.unknownKey(token)
        }
    }

    /// The N in an `fN` token (case-insensitive), or nil if not an F-key token.
    private static func fKeyNumber(_ token: String) -> Int? {
        let lower = token.lowercased()
        guard lower.hasPrefix("f") else { return nil }
        return Int(lower.dropFirst())
    }
}
