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
    /// level. The root is named by `command` (the file stem).
    ///
    /// The spec object is the one `export default` names (an object literal or a top-level
    /// `const`); without an `export default`, the `completionSpec` const, then the first brace
    /// outside an import. References are resolved statically within the file: a top-level
    /// `const` used as a member, a member access into one (`sharedCommands.build`), an array
    /// or option list held in one, and `...spreads` of either. Calls, computed access
    /// (`a[b]`), generators and `loadSpec` contribute nothing; there is no cross-file
    /// resolution. Malformed or empty source yields a spec with no members.
    static func spec(fromSource source: String, command: String, maxDepth: Int = 3) -> FigCommandSpec {
        let tokens = tokenize(source, operators: true)
        let walker = FigWalker(tokens: tokens, bindings: topLevelBindings(in: tokens), maxDepth: maxDepth)
        guard let open = walker.specObjectStart() else {
            return FigCommandSpec(names: [command], subcommands: [], options: [])
        }
        let level = walker.parseObject(at: open, depth: 0, collectChildren: true, nesting: 0)
        return FigCommandSpec(names: [command], subcommands: level.subcommands ?? [], options: level.options ?? [])
    }
}

/// Index of the value token of every top-level `const` / `let` / `var NAME ... = value`
/// (the first binding of a name wins).
private func topLevelBindings(in tokens: [FigSpecParser.Token]) -> [String: Int] {
    var bindings: [String: Int] = [:]
    var depth = 0
    var i = 0
    while i < tokens.count {
        switch tokens[i] {
        case .punct("{"), .punct("["), .punct("("):
            depth += 1
        case .punct("}"), .punct("]"), .punct(")"):
            depth = max(0, depth - 1)
        case .ident(let keyword) where depth == 0 && ["const", "let", "var"].contains(keyword):
            guard i + 1 < tokens.count, case .ident(let name) = tokens[i + 1] else { break }
            if let value = assignmentValue(in: tokens, from: i + 2), bindings[name] == nil {
                bindings[name] = value
            }
        default:
            break
        }
        i += 1
    }
    return bindings
}

/// Index just past the `=` that ends a declaration's (optional) type annotation, or nil when
/// the declaration has no initializer.
private func assignmentValue(in tokens: [FigSpecParser.Token], from start: Int) -> Int? {
    var depth = 0
    var i = start
    while i < tokens.count {
        switch tokens[i] {
        case .punct("{"), .punct("["), .punct("("):
            depth += 1
        case .punct("}"), .punct("]"), .punct(")"):
            if depth == 0 { return nil }
            depth -= 1
        case .punct("=") where depth == 0:
            return i + 1 < tokens.count ? i + 1 : nil
        case .ident(let word) where depth == 0 && ["const", "let", "var", "export", "function"].contains(word):
            return nil
        default:
            break
        }
        i += 1
    }
    return nil
}

/// Recursive walk over the token stream produced by the Fig tokenizer, resolving references to
/// top-level bindings.
private struct FigWalker {
    let tokens: [FigSpecParser.Token]
    let bindings: [String: Int]
    let maxDepth: Int

    /// Bound on chained reference hops and nested spreads, so cyclic bindings terminate.
    private let maxNesting = 16

    /// The fields an object literal sets; nil when the object does not set that key.
    struct Level {
        var names: [String]?
        var subcommands: [FigCommandSpec]?
        var options: [String]?
        var end: Int

        /// Applies the fields `other` sets on top of these (a spread or a later key wins).
        mutating func overlay(_ other: Level) {
            if let names = other.names { self.names = names }
            if let subcommands = other.subcommands { self.subcommands = subcommands }
            if let options = other.options { self.options = options }
        }
    }

    /// Index of the spec object's `{`, or nil when it cannot be located statically.
    func specObjectStart() -> Int? {
        if let expression = exportDefaultExpression() { return resolveObject(at: expression) }
        if let value = bindings["completionSpec"] { return resolveObject(at: value) }
        return firstBraceOutsideImports()
    }

    /// Index of the expression after a top-level `export default`, or nil when there is none.
    private func exportDefaultExpression() -> Int? {
        var depth = 0
        for i in tokens.indices {
            switch tokens[i] {
            case .punct("{"), .punct("["), .punct("("):
                depth += 1
            case .punct("}"), .punct("]"), .punct(")"):
                depth = max(0, depth - 1)
            case .ident("export") where depth == 0 && i + 2 < tokens.count && tokens[i + 1] == .ident("default"):
                return i + 2
            default:
                break
            }
        }
        return nil
    }

    private func firstBraceOutsideImports() -> Int? {
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

    // MARK: - Reference resolution

    /// The `{` or `[` literal the expression at `i` denotes: a literal itself, or
    /// `NAME(.key)*` through top-level bindings. Nil for calls, computed access, unknown names.
    private func resolve(at i: Int, hops: Int = 0) -> Int? {
        guard i < tokens.count, hops <= maxNesting else { return nil }
        switch tokens[i] {
        case .punct("{"), .punct("["):
            return i
        case .ident(let name):
            guard let value = bindings[name], var target = resolve(at: value, hops: hops + 1) else { return nil }
            var j = i + 1
            while j + 1 < tokens.count, tokens[j] == .punct("."), case .ident(let key) = tokens[j + 1] {
                guard tokens[target] == .punct("{"),
                      let member = valueIndex(ofKey: key, inObjectAt: target, hops: hops + 1),
                      let next = resolve(at: member, hops: hops + 1) else { return nil }
                target = next
                j += 2
            }
            if j < tokens.count, tokens[j] == .punct("(") || tokens[j] == .punct("[") || tokens[j] == .punct(".") {
                return nil   // a call, computed access or unresolved chain
            }
            return target
        default:
            return nil
        }
    }

    private func resolveObject(at i: Int) -> Int? {
        guard let target = resolve(at: i), tokens[target] == .punct("{") else { return nil }
        return target
    }

    private func resolveArray(at i: Int) -> Int? {
        guard let target = resolve(at: i), tokens[target] == .punct("[") else { return nil }
        return target
    }

    /// Index of the value of `key` in the object at `start` (the last definition wins,
    /// including one brought in by a spread).
    private func valueIndex(ofKey key: String, inObjectAt start: Int, hops: Int) -> Int? {
        guard hops <= maxNesting else { return nil }
        var found: Int?
        var i = start + 1
        while i < tokens.count {
            let token = tokens[i]
            if token == .punct("}") { return found }
            if token == .punct(",") {
                i += 1
                continue
            }
            if token == .spread {
                if let inner = resolve(at: i + 1, hops: hops + 1), tokens[inner] == .punct("{"),
                   let value = valueIndex(ofKey: key, inObjectAt: inner, hops: hops + 1) {
                    found = value
                }
                i = advance(past: i + 1)
                continue
            }
            if let name = keyName(at: i), i + 1 < tokens.count, tokens[i + 1] == .punct(":") {
                if name == key { found = i + 2 }
                i = advance(past: i + 2)
                continue
            }
            i = advance(past: i)
        }
        return found
    }

    // MARK: - Objects and members

    /// Parses the object whose `{` is at `start`; `end` is the index just past its `}`.
    /// With `collectChildren` false (an option member) only the names are read.
    func parseObject(at start: Int, depth: Int, collectChildren: Bool, nesting: Int) -> Level {
        var level = Level(end: tokens.count)
        var i = start + 1
        while i < tokens.count {
            let token = tokens[i]
            if token == .punct("}") {
                level.end = i + 1
                return level
            }
            if token == .punct(",") {
                i += 1
                continue
            }
            if token == .spread {
                if nesting < maxNesting, let inner = resolveObject(at: i + 1) {
                    level.overlay(parseObject(at: inner, depth: depth, collectChildren: collectChildren,
                                              nesting: nesting + 1))
                }
                i = advance(past: i + 1)
                continue
            }
            if let key = keyName(at: i), i + 1 < tokens.count, tokens[i + 1] == .punct(":") {
                parseValue(key: key, at: i + 2, depth: depth, collectChildren: collectChildren,
                           nesting: nesting, into: &level)
                i = advance(past: i + 2)
                continue
            }
            i = advance(past: i)   // method shorthand, stray tokens
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

    /// Records the value of `key` starting at `i` into `level` when it is one the tree uses.
    private func parseValue(key: String, at i: Int, depth: Int, collectChildren: Bool,
                            nesting: Int, into level: inout Level) {
        guard i < tokens.count else { return }
        switch key {
        case "name":
            if let names = parseNames(at: i) { level.names = names }
        case "subcommands" where collectChildren && depth < maxDepth:
            guard let array = resolveArray(at: i) else { return }
            var subcommands: [FigCommandSpec] = []
            parseMembers(at: array, depth: depth, collectChildren: true, nesting: nesting) { subcommands.append($0) }
            level.subcommands = subcommands
        case "options" where collectChildren:
            guard let array = resolveArray(at: i) else { return }
            var options: [String] = []
            parseMembers(at: array, depth: depth, collectChildren: false, nesting: nesting) {
                options.append(contentsOf: $0.names)
            }
            level.options = options
        default:
            return
        }
    }

    /// A string name, or an array (literal or referenced) of alias strings. Templated and
    /// computed names are ignored; nil when the value is not a name at all.
    private func parseNames(at i: Int) -> [String]? {
        if case .string(let value, let template) = tokens[i] {
            return template ? [] : [value]
        }
        guard let open = resolveArray(at: i) else { return nil }
        var names: [String] = []
        var idx = open + 1
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
        return names
    }

    /// Walks the member array at `start`: object literals, references to objects, and spreads
    /// of referenced arrays. Each member with a name is handed to `emit` as a spec.
    private func parseMembers(at start: Int, depth: Int, collectChildren: Bool, nesting: Int,
                              emit: (FigCommandSpec) -> Void) {
        var i = start + 1
        while i < tokens.count {
            let token = tokens[i]
            if token == .punct("]") { return }
            if token == .punct(",") {
                i += 1
                continue
            }
            if token == .spread {
                if nesting < maxNesting, let inner = resolveArray(at: i + 1) {
                    parseMembers(at: inner, depth: depth, collectChildren: collectChildren,
                                 nesting: nesting + 1, emit: emit)
                }
                i = advance(past: i + 1)
                continue
            }
            if let object = resolveObject(at: i) {
                let member = parseObject(at: object, depth: depth + 1, collectChildren: collectChildren,
                                         nesting: nesting)
                if let names = member.names, !names.isEmpty {
                    emit(FigCommandSpec(names: names, subcommands: member.subcommands ?? [],
                                        options: member.options ?? []))
                }
            }
            i = advance(past: i)
        }
    }

    /// Index of the `,` or closing bracket that ends the expression starting at `start`
    /// (balanced over braces, brackets and parens); always past `start` unless `start` is
    /// itself a closer.
    private func advance(past start: Int) -> Int {
        var depth = 0
        var i = start
        while i < tokens.count {
            switch tokens[i] {
            case .punct("{"), .punct("["), .punct("("):
                depth += 1
            case .punct("}"), .punct("]"), .punct(")"):
                if depth == 0 { return i == start ? i + 1 : i }
                depth -= 1
            case .punct(",") where depth == 0:
                return i == start ? i + 1 : i
            default:
                break
            }
            i += 1
        }
        return i
    }
}
