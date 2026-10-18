// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import SemicolynKit

/// Serialization limits of the `GCMT` format: names are 1...255 bytes, at most 255 children or
/// flags per node, nesting depth at most 4.
private let maxNameBytes = 255
private let maxPerNode = 255
private let maxTreeDepth = 4

/// Score of `count` relative to the best sibling: `1 + round(254 * ln(1 + c) / ln(1 + max))`.
/// A zero count (or an all-zero group) scores 1; the best sibling scores 255.
private func relativeScore(_ count: Int, max best: Int) -> UInt8 {
    guard count > 0, best > 0 else { return 1 }
    let ratio = log(1 + Double(count)) / log(1 + Double(best))
    return UInt8(min(255, 1 + Int((254 * ratio).rounded())))
}

private func isStorable(_ name: String) -> Bool {
    !name.isEmpty && name.utf8.count <= maxNameBytes
}

/// Builds the shipped command tree. Tools are those with a Fig spec or a usage count (top
/// `maxTools` by count, ties by name). Children come only from Fig structure and are ranked by
/// how often tldr uses their path; each alias is its own child. A node's flags are those seen in
/// tldr for its path plus `--help` when Fig declares it. Names that cannot be serialized are
/// skipped and each node is capped to its 255 best children and flags.
public func buildCommandTree(specs: [FigCommandSpec], usage: CommandUsage, maxTools: Int = 400) -> CommandTree {
    let parts = buildCommandTreeParts(specs: specs, usage: usage, maxTools: maxTools)
    return CommandTree(tools: parts.tools, pipeTargets: parts.pipeTargets)
}

/// Total number of nodes in `nodes` and all their descendants.
public func countNodes(_ nodes: [CommandNode]) -> Int {
    nodes.reduce(0) { $0 + 1 + countNodes($1.children) }
}

/// The tools and pipe targets ``buildCommandTree`` wraps, exposed so callers can report counts.
public func buildCommandTreeParts(specs: [FigCommandSpec], usage: CommandUsage,
                                  maxTools: Int = 400) -> (tools: [CommandNode], pipeTargets: [ScoredWord]) {
    var figByTool: [String: FigCommandSpec] = [:]
    for spec in specs {
        for name in spec.names where isStorable(name) && figByTool[name] == nil { figByTool[name] = spec }
    }
    var usage = usage
    usage.flagCounts = rolledUpFlags(usage.flagCounts, figByTool: figByTool)
    let candidates = Set(figByTool.keys).union(usage.toolCounts.keys.filter(isStorable))
    let ranked = candidates.sorted { a, b in
        let ca = usage.toolCounts[a] ?? 0, cb = usage.toolCounts[b] ?? 0
        return ca != cb ? ca > cb : a.utf8.lexicographicallyPrecedes(b.utf8)
    }
    let kept = Array(ranked.prefix(max(0, maxTools)))
    let best = kept.map { usage.toolCounts[$0] ?? 0 }.max() ?? 0
    let tools = kept.map { name in
        let count = usage.toolCounts[name] ?? 0
        return node(name: name, score: relativeScore(count, max: best), path: [name],
                    fig: figByTool[name], usage: usage, depth: 1, flagPaths: [[name]])
    }

    let pipeRanked = usage.pipeTargetCounts.filter { isStorable($0.key) }.sorted { a, b in
        a.value != b.value ? a.value > b.value : a.key.utf8.lexicographicallyPrecedes(b.key.utf8)
    }.prefix(max(0, maxTools))
    let pipeBest = pipeRanked.first?.value ?? 0
    let pipes = pipeRanked.map { ScoredWord(text: $0.key, score: relativeScore($0.value, max: pipeBest)) }
    return (tools, pipes)
}

private func node(name: String, score: UInt8, path: [String], fig: FigCommandSpec?,
                  usage: CommandUsage, depth: Int, flagPaths: [[String]]) -> CommandNode {
    CommandNode(name: name, score: score,
                children: children(of: fig, path: path, usage: usage, depth: depth),
                flags: flags(paths: flagPaths, fig: fig, usage: usage))
}

private func children(of fig: FigCommandSpec?, path: [String], usage: CommandUsage, depth: Int) -> [CommandNode] {
    guard let fig, depth < maxTreeDepth else { return [] }
    // Each Fig member with its usage count (all aliases pooled); stable sort keeps Fig order on ties.
    let members = fig.subcommands.enumerated().map { index, sub -> (index: Int, spec: FigCommandSpec, count: Int) in
        let count = sub.names.reduce(0) { $0 + (usage.pathCounts[path + [$1]] ?? 0) }
        return (index, sub, count)
    }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.index < $1.index }
    let best = members.map(\.count).max() ?? 0

    var out: [CommandNode] = []
    for member in members {
        let score = relativeScore(member.count, max: best)
        for alias in member.spec.names where isStorable(alias) {
            guard out.count < maxPerNode else { return out }
            out.append(node(name: alias, score: score, path: path + [alias], fig: member.spec,
                            usage: usage, depth: depth + 1,
                            flagPaths: member.spec.names.map { path + [$0] }))
        }
    }
    return out
}

/// Flags for a node. `paths` are the node's own path and its aliases' paths; their counts pool.
private func flags(paths: [[String]], fig: FigCommandSpec?, usage: CommandUsage) -> [ScoredWord] {
    var counts: [String: Int] = [:]
    for path in paths {
        for (flag, n) in usage.flagCounts[path] ?? [:] { counts[flag, default: 0] += n }
    }
    if fig?.options.contains("--help") == true, counts["--help"] == nil { counts["--help"] = 0 }
    let best = counts.values.max() ?? 0
    let ordered = counts.filter { isStorable($0.key) }.sorted { a, b in
        a.value != b.value ? a.value > b.value : a.key.utf8.lexicographicallyPrecedes(b.key.utf8)
    }
    return ordered.prefix(maxPerNode).map { ScoredWord(text: $0.key, score: relativeScore($0.value, max: best)) }
}

/// Moves flag counts recorded under paths that are not nodes of the built tree (a positional
/// such as `ls /tmp -l`) up to the deepest ancestor that is one.
private func rolledUpFlags(_ flagCounts: [[String]: [String: Int]],
                           figByTool: [String: FigCommandSpec]) -> [[String]: [String: Int]] {
    var rolled: [[String]: [String: Int]] = [:]
    for (path, counts) in flagCounts {
        var node = figByTool[path[0]]
        var resolved = [path[0]]
        for word in path.dropFirst() {
            guard let child = node?.subcommands.first(where: { $0.names.contains(word) }),
                  resolved.count < maxTreeDepth else { break }
            node = child
            resolved.append(word)
        }
        for (flag, n) in counts { rolled[resolved, default: [:]][flag, default: 0] += n }
    }
    return rolled
}
