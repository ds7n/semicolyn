// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// One tool or subcommand: its own score, nested subcommands, and flags.
public struct CommandNode: Equatable, Sendable {
    public let name: String
    public let score: UInt8
    public let children: [CommandNode]
    public let flags: [ScoredWord]

    public init(name: String, score: UInt8, children: [CommandNode], flags: [ScoredWord]) {
        self.name = name
        self.score = score
        self.children = children
        self.flags = flags
    }
}

/// The shipped command knowledge: tools with nested subcommands and flags, plus
/// pipe-target ranking. Serialized as the `GCMT` v1 binary format.
///
/// Layout (little-endian): `47 43 4d 54 | version u8 = 1 | toolCount u16`, then nodes
/// depth-first as `len u8 | name | score u8 | flagCount u8 | flags (len u8 | text | score u8)...
/// | childCount u8 | children...`, then `pipeCount u16` and pipe targets encoded as flags.
/// Maximum nesting depth is 4 (the reader fails closed on deeper trees).
public struct CommandTree: Sendable {
    private static let magic: [UInt8] = [0x47, 0x43, 0x4d, 0x54]
    private static let version: UInt8 = 1
    private static let maxDepth = 4

    private let tools: [CommandNode]
    private let pipeTargets: [ScoredWord]

    public init(tools: [CommandNode], pipeTargets: [ScoredWord]) {
        self.tools = tools
        self.pipeTargets = pipeTargets
    }

    /// Number of top-level tools (for the App's load log).
    public var toolCount: Int { tools.count }

    /// Exact, case-sensitive tool-name lookup.
    public func isKnownTool(_ word: String) -> Bool {
        tools.contains { $0.name == word }
    }

    /// Context-aware candidates for `typed`, given the words already in the current
    /// command segment. Results are case-matched, best `limit` first.
    public func candidates(segmentWords: [String], typed: String, afterPipe: Bool, limit: Int) -> [ScoredWord] {
        guard limit > 0 else { return [] }
        let raw: [ScoredWord]
        if segmentWords.isEmpty {
            raw = topLevel(afterPipe: afterPipe)
        } else {
            guard let tool = tools.first(where: { $0.name == segmentWords[0] }) else { return [] }
            raw = contextual(from: tool, later: segmentWords.dropFirst(), typed: typed)
        }
        var matched: [ScoredWord] = []
        for item in raw {
            guard let display = caseMatchedForm(typed: typed, candidate: item.text) else { continue }
            matched.append(ScoredWord(text: display, score: item.score))
        }
        matched.sort(by: CommandTree.ranksBefore)
        return Array(matched.prefix(limit))
    }

    private func topLevel(afterPipe: Bool) -> [ScoredWord] {
        let toolWords = tools.map { ScoredWord(text: $0.name, score: $0.score) }
        guard afterPipe else { return toolWords }
        let piped = Set(pipeTargets.map(\.text))
        return pipeTargets + toolWords.filter { !piped.contains($0.text) }.map {
            ScoredWord(text: $0.text, score: $0.score / 2)
        }
    }

    private func contextual(from tool: CommandNode, later: ArraySlice<String>, typed: String) -> [ScoredWord] {
        var node = tool
        var positional = false
        for word in later {
            if let child = node.children.first(where: { $0.name == word }) {
                node = child
            } else if word.hasPrefix("-") {
                continue
            } else {
                positional = true
                break
            }
        }
        if typed.hasPrefix("-") { return node.flags }
        if positional { return [] }
        if !node.children.isEmpty { return node.children.map { ScoredWord(text: $0.name, score: $0.score) } }
        return typed.isEmpty ? node.flags : []
    }

    private static func ranksBefore(_ a: ScoredWord, _ b: ScoredWord) -> Bool {
        if a.score != b.score { return a.score > b.score }
        return a.text.utf8.lexicographicallyPrecedes(b.text.utf8)
    }

    // MARK: - Serialization

    /// Encodes the tree as `GCMT` v1. Names are expected to be 1...255 bytes.
    public func serialize() -> [UInt8] {
        var out = CommandTree.magic
        out.append(CommandTree.version)
        appendLE16(&out, UInt16(tools.count))
        for tool in tools { CommandTree.write(tool, to: &out) }
        appendLE16(&out, UInt16(pipeTargets.count))
        for target in pipeTargets { CommandTree.write(target, to: &out) }
        return out
    }

    private static func write(_ word: ScoredWord, to out: inout [UInt8]) {
        let bytes = Array(word.text.utf8)
        out.append(UInt8(bytes.count))
        out += bytes
        out.append(word.score)
    }

    private static func write(_ node: CommandNode, to out: inout [UInt8]) {
        write(ScoredWord(text: node.name, score: node.score), to: &out)
        out.append(UInt8(node.flags.count))
        for flag in node.flags { write(flag, to: &out) }
        out.append(UInt8(node.children.count))
        for child in node.children { write(child, to: &out) }
    }

    /// Decodes `GCMT` v1, failing closed (nil) on any structural violation.
    public init?(deserializing bytes: [UInt8]) {
        guard bytes.count >= 7, Array(bytes[0..<4]) == CommandTree.magic,
            bytes[4] == CommandTree.version
        else { return nil }
        var pos = 5
        guard let toolCount = CommandTree.readU16(bytes, &pos) else { return nil }
        var tools: [CommandNode] = []
        for _ in 0..<toolCount {
            guard let tool = CommandTree.readNode(bytes, &pos, depth: 1) else { return nil }
            tools.append(tool)
        }
        guard let pipeCount = CommandTree.readU16(bytes, &pos) else { return nil }
        var pipes: [ScoredWord] = []
        for _ in 0..<pipeCount {
            guard let word = CommandTree.readWord(bytes, &pos) else { return nil }
            pipes.append(word)
        }
        guard pos == bytes.count else { return nil }
        self.init(tools: tools, pipeTargets: pipes)
    }

    private static func readU16(_ bytes: [UInt8], _ pos: inout Int) -> Int? {
        guard pos + 2 <= bytes.count else { return nil }
        let value = Int(bytes[pos]) | (Int(bytes[pos + 1]) << 8)
        pos += 2
        return value
    }

    private static func readU8(_ bytes: [UInt8], _ pos: inout Int) -> Int? {
        guard pos < bytes.count else { return nil }
        defer { pos += 1 }
        return Int(bytes[pos])
    }

    private static func readWord(_ bytes: [UInt8], _ pos: inout Int) -> ScoredWord? {
        guard let len = readU8(bytes, &pos), len > 0, pos + len + 1 <= bytes.count else { return nil }
        let raw = Array(bytes[pos..<pos + len])
        let score = bytes[pos + len]
        pos += len + 1
        let text = String(decoding: raw, as: UTF8.self)
        guard Array(text.utf8) == raw else { return nil }
        return ScoredWord(text: text, score: score)
    }

    private static func readNode(_ bytes: [UInt8], _ pos: inout Int, depth: Int) -> CommandNode? {
        guard depth <= maxDepth, let head = readWord(bytes, &pos), let flagCount = readU8(bytes, &pos) else {
            return nil
        }
        var flags: [ScoredWord] = []
        for _ in 0..<flagCount {
            guard let flag = readWord(bytes, &pos) else { return nil }
            flags.append(flag)
        }
        guard let childCount = readU8(bytes, &pos) else { return nil }
        var children: [CommandNode] = []
        for _ in 0..<childCount {
            guard let child = readNode(bytes, &pos, depth: depth + 1) else { return nil }
            children.append(child)
        }
        return CommandNode(name: head.text, score: head.score, children: children, flags: flags)
    }
}

private func appendLE16(_ out: inout [UInt8], _ value: UInt16) {
    out.append(UInt8(value & 0xff))
    out.append(UInt8(value >> 8))
}
