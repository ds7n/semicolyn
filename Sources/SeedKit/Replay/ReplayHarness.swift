// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import SemicolynKit

/// A suggestion engine under evaluation: given the text typed so far on a line, the
/// ordered chips it would show; and told when a full line is committed (for learning).
public protocol ReplayPredictor {
    mutating func suggestions(line: String) -> [String]
    mutating func commit(line: String)
}

/// Knobs for a replay run.
public struct ReplayConfig: Sendable {
    /// How many leading suggestions the user can see and tap.
    public var visibleSlots: Int
    /// Whether each finished line is fed back to the predictor via `commit`.
    public var learn: Bool

    public init(visibleSlots: Int = 5, learn: Bool = false) {
        self.visibleSlots = visibleSlots
        self.learn = learn
    }
}

/// Aggregate quality numbers from one replay. Equality ignores `latenciesMs`
/// (wall-clock noise).
public struct ReplayReport: Equatable, Sendable {
    public var keystrokes: Int
    public var keystrokesSaved: Int
    public var lookups: Int
    public var emptyLookups: Int
    public var hitsBySlot: [Int]
    public var latenciesMs: [Double]

    public init(keystrokes: Int, keystrokesSaved: Int, lookups: Int, emptyLookups: Int,
                hitsBySlot: [Int], latenciesMs: [Double]) {
        self.keystrokes = keystrokes
        self.keystrokesSaved = keystrokesSaved
        self.lookups = lookups
        self.emptyLookups = emptyLookups
        self.hitsBySlot = hitsBySlot
        self.latenciesMs = latenciesMs
    }

    /// Keystrokes saved per 100 typed characters.
    public var savedPer100: Double {
        keystrokes == 0 ? 0 : Double(keystrokesSaved) * 100 / Double(keystrokes)
    }

    /// Fraction of mid-token lookups that returned no suggestion at all.
    public var zeroRate: Double {
        lookups == 0 ? 0 : Double(emptyLookups) / Double(lookups)
    }

    /// 95th percentile (nearest rank) of per-lookup latency in milliseconds.
    public var p95LatencyMs: Double {
        guard !latenciesMs.isEmpty else { return 0 }
        let sorted = latenciesMs.sorted()
        let rank = Int((0.95 * Double(sorted.count)).rounded(.up))
        return sorted[max(0, min(sorted.count - 1, rank - 1))]
    }

    public static func == (lhs: ReplayReport, rhs: ReplayReport) -> Bool {
        lhs.keystrokes == rhs.keystrokes && lhs.keystrokesSaved == rhs.keystrokesSaved
            && lhs.lookups == rhs.lookups && lhs.emptyLookups == rhs.emptyLookups
            && lhs.hitsBySlot == rhs.hitsBySlot
    }
}

/// Replays `lines` character by character against `predictor`, taking a chip whenever the
/// word at the cursor appears in the visible slots, and counts the keystrokes that saves.
/// Taking a chip jumps to the end of the word; a chip adds a trailing space unless the
/// word ends in `/` or `=`, which is free when the line has that space and otherwise
/// costs one keystroke to delete.
public func replay<P: ReplayPredictor>(lines: [String], predictor: inout P,
                                       config: ReplayConfig) -> ReplayReport {
    var report = ReplayReport(keystrokes: 0, keystrokesSaved: 0, lookups: 0, emptyLookups: 0,
                              hitsBySlot: Array(repeating: 0, count: max(0, config.visibleSlots)),
                              latenciesMs: [])
    let clock = ContinuousClock()
    for line in lines {
        let chars = Array(line)
        report.keystrokes += chars.count
        var typedCount = 0
        var endedOnJump = false

        /// Queries the predictor for the first `n` characters and books latency and lookup counts.
        func lookup(_ n: Int, tokenStart: Int) -> [String] {
            var results: [String] = []
            let elapsed = clock.measure { results = predictor.suggestions(line: String(chars[0..<n])) }
            let parts = elapsed.components
            report.latenciesMs.append(Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15)
            guard n > tokenStart else { return results }
            report.lookups += 1
            if results.isEmpty { report.emptyLookups += 1 }
            return results
        }

        while typedCount < chars.count {
            endedOnJump = false
            let tokenStart = (chars[0..<typedCount].lastIndex(of: " ")).map { $0 + 1 } ?? 0
            let tokenEnd = chars[tokenStart...].firstIndex(of: " ") ?? chars.count
            let word = lookupWord(fromToken: String(chars[tokenStart..<tokenEnd]))
            let wordStart = tokenStart + word.leading.count
            let wordEnd = wordStart + word.word.count

            let results = lookup(typedCount, tokenStart: tokenStart)

            let hasTarget = !word.word.isEmpty && typedCount >= wordStart && typedCount < wordEnd
            let slot = hasTarget ? results.prefix(config.visibleSlots).firstIndex(of: word.word) : nil
            guard let slot else {
                typedCount += 1
                continue
            }
            report.hitsBySlot[slot] += 1
            var jumpTo = wordEnd
            var extra = 0
            if let last = word.word.last, last != "/", last != "=" {
                if jumpTo < chars.count, chars[jumpTo] == " " {
                    jumpTo += 1
                } else if jumpTo < chars.count {
                    extra = 1
                }
            }
            report.keystrokesSaved += (jumpTo - typedCount) - 1 - extra
            typedCount = jumpTo
            endedOnJump = true
        }
        // A line finished by typing (not by taking a chip) still shows its final suggestions.
        if !endedOnJump, !chars.isEmpty {
            let tokenStart = (chars.lastIndex(of: " ")).map { $0 + 1 } ?? 0
            _ = lookup(chars.count, tokenStart: tokenStart)
        }
        if config.learn { predictor.commit(line: line) }
    }
    return report
}
