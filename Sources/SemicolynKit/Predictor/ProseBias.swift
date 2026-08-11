// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// How a foreground process reads for prose-vs-CLI intent.
enum ProcessClass: Equatable { case prose, cli, unknown }

private let proseProcesses: Set<String> = [
    "claude", "python", "python3", "node", "irb", "ipython",
    "vim", "nvim", "emacs", "ghci", "ruby",
]
private let cliProcesses: Set<String> = [
    "bash", "zsh", "fish", "sh", "dash", "ksh",
]
/// First-token binaries that mark a line as a command, not prose (line-shape gate).
private let knownBinaries: Set<String> = [
    "git", "ls", "cd", "cat", "grep", "chmod", "chown", "ssh", "scp", "docker",
    "kubectl", "npm", "cargo", "make", "sudo", "rm", "cp", "mv", "curl", "tar",
]

/// Classify a foreground process name by its lowercased basename.
func classifyProcess(_ name: String?) -> ProcessClass {
    guard let name, !name.isEmpty else { return .unknown }
    let base = (name as NSString).lastPathComponent.lowercased()
    if proseProcesses.contains(base) { return .prose }
    if cliProcesses.contains(base) { return .cli }
    return .unknown
}

/// Prose-vs-CLI bias in `[0,1]` (0 = pure CLI, 1 = pure prose). Signals abstain when
/// nil. Magnitudes are the spec's tunable starting points.
func proseBias(_ context: PredictionContext) -> Double {
    if context.allSignalsNil { return 0.15 }   // CLI-safe blind prior

    var b = 0.5
    let cls = classifyProcess(context.foregroundProcess)
    switch cls {
    case .prose: b += 0.35
    case .cli:   b -= 0.35
    case .unknown: break
    }

    // Alt-screen modifies the process vote (never rescues a CLI process).
    if context.isAlternateScreen == true, cls != .cli { b += 0.15 }

    // Line-shape: only a sentence-shaped line (>=2 words, first not a binary) nudges.
    if let line = context.line {
        let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        if words.count >= 2 {
            let first = words[0].lowercased()
            if !knownBinaries.contains(first) { b += 0.15 }
        }
    }

    return min(1.0, max(0.0, b))
}
