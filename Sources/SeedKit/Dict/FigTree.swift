// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// One level of a Fig completion spec: the names (all aliases) of a command or subcommand, its
/// nested subcommands, and the option names declared at this level.
public struct FigCommandSpec: Equatable {
    public let names: [String]
    public let subcommands: [FigCommandSpec]
    public let options: [String]

    public init(names: [String], subcommands: [FigCommandSpec], options: [String]) {
        self.names = names
        self.subcommands = subcommands
        self.options = options
    }
}

public extension FigSpecParser {
    /// Parses the nested structure of a Fig spec: `subcommands:` arrays down to `maxDepth`
    /// levels below the root, every alias of a member `name`, and the `options:` names per
    /// level. The root is named by `command` (the file stem). Subcommands that are not object
    /// literals (`loadSpec`, generators) contribute nothing; there is no cross-file resolution.
    /// Malformed or empty source yields a spec with no members.
    static func spec(fromSource source: String, command: String, maxDepth: Int = 3) -> FigCommandSpec {
        let tokens = tokenize(source)
        guard let open = specObjectStart(in: tokens) else {
            return FigCommandSpec(names: [command], subcommands: [], options: [])
        }
        var walker = FigWalker(tokens: tokens, maxDepth: maxDepth)
        let level = walker.parseObject(at: open, depth: 0)
        return FigCommandSpec(names: [command], subcommands: level.subcommands, options: level.options)
    }
}

/// Index of the spec's own `{`: the first brace outside an `import ... from "x"` statement.
private func specObjectStart(in tokens: [FigSpecParser.Token]) -> Int? {
    var i = 0
    while i < tokens.count {
        if tokens[i] == .ident("import") {
            while i < tokens.count {
                if case .string = tokens[i] { break }
                i += 1
            }
        } else if tokens[i] == .punct("{") {
            return i
        }
        i += 1
    }
    return nil
}

/// Recursive walk over the token stream produced by the Fig tokenizer.
private struct FigWalker {
    let tokens: [FigSpecParser.Token]
    let maxDepth: Int

    struct Level {
        var names: [String] = []
        var subcommands: [FigCommandSpec] = []
        var options: [String] = []
        var end: Int
    }

    /// Parses the object whose `{` is at `start`; `end` is the index just past its `}`.
    mutating func parseObject(at start: Int, depth: Int) -> Level {
        var level = Level(end: tokens.count)
        var i = start + 1
        var previousOpensKey = true   // a key may follow `{` or `,`
        while i < tokens.count {
            let token = tokens[i]
            if case .punct("}") = token {
                level.end = i + 1
                return level
            }
            if case .punct(let p) = token, p == "{" || p == "[" {
                i = skipBalanced(from: i)
                previousOpensKey = false
                continue
            }
            if previousOpensKey, let key = keyName(at: i), i + 1 < tokens.count, tokens[i + 1] == .punct(":") {
                i += 2
                i = parseValue(key: key, at: i, depth: depth, into: &level)
                previousOpensKey = false
                continue
            }
            previousOpensKey = token == .punct(",")
            i += 1
        }
        return level
    }

    private func keyName(at i: Int) -> String? {
        switch tokens[i] {
        case .ident(let name): return name
        case .string(let value, template: false): return value
        default: return nil
        }
    }

    /// Handles the value of `key` starting at `i`; returns the index to continue from.
    private mutating func parseValue(key: String, at i: Int, depth: Int, into level: inout Level) -> Int {
        guard i < tokens.count else { return i }
        switch key {
        case "name":
            return parseNames(at: i, into: &level.names)
        case "subcommands" where depth < maxDepth:
            guard tokens[i] == .punct("[") else { return i }
            return parseMembers(at: i, depth: depth) { level.subcommands.append($0) }
        case "options":
            guard tokens[i] == .punct("[") else { return i }
            return parseMembers(at: i, depth: depth) { level.options.append(contentsOf: $0.names) }
        default:
            return i
        }
    }

    /// A string name, or an array of alias strings. Templated and computed names are ignored.
    private func parseNames(at i: Int, into names: inout [String]) -> Int {
        if case .string(let value, let template) = tokens[i] {
            if !template { names.append(value) }
            return i + 1
        }
        guard tokens[i] == .punct("[") else { return i }
        var idx = i + 1
        var depth = 1
        while idx < tokens.count, depth > 0 {
            switch tokens[idx] {
            case .punct("["): depth += 1
            case .punct("]"): depth -= 1
            case .string(let value, let template) where depth == 1 && !template: names.append(value)
            default: break
            }
            idx += 1
        }
        return idx
    }

    /// Walks an array of member objects starting at its `[`, handing each named member (as a
    /// spec) to `emit`. Members without a name are dropped. Returns the index past the `]`.
    private mutating func parseMembers(at start: Int, depth: Int, emit: (FigCommandSpec) -> Void) -> Int {
        var i = start + 1
        while i < tokens.count {
            switch tokens[i] {
            case .punct("]"):
                return i + 1
            case .punct("{"):
                let member = parseObject(at: i, depth: depth + 1)
                i = member.end
                if !member.names.isEmpty {
                    emit(FigCommandSpec(names: member.names, subcommands: member.subcommands, options: member.options))
                }
            case .punct("["):
                i = skipBalanced(from: i)
            default:
                i += 1
            }
        }
        return i
    }

    /// Index just past the bracket/brace group opened at `start`.
    private func skipBalanced(from start: Int) -> Int {
        var depth = 0
        var i = start
        while i < tokens.count {
            switch tokens[i] {
            case .punct("{"), .punct("["): depth += 1
            case .punct("}"), .punct("]"):
                depth -= 1
                if depth == 0 { return i + 1 }
            default: break
            }
            i += 1
        }
        return i
    }
}
