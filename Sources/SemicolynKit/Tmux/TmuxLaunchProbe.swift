// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Classification of the first output seen after an in-band `tmux new -A -s <name>`
/// launch over a transport that cannot pre-probe (Mosh/ET). The App accumulates the
/// watch window's bytes and passes the whole accumulation; the timeout/window policy
/// lives in the App (inconclusive at expiry -> assume started).
public enum TmuxLaunchProbe: Equatable, Sendable {
    case tmuxMissing
    case tmuxStarted
    case inconclusive
}

/// The alt-screen enter private-mode sets tmux emits when it attaches. Positive
/// evidence tmux is up (an app INSIDE tmux has not started yet at launch time).
private let altScreenEnter: [String] = ["\u{1B}[?1049h", "\u{1B}[?1047h", "\u{1B}[?47h"]

/// Shell "command not found" diagnostics that name tmux. Matched as a line shape
/// (a `not found` diagnostic mentioning `tmux`), not the bare token `tmux`, so a
/// benign mention of the word cannot trip a false positive.
private func lineIsTmuxNotFound(_ line: Substring) -> Bool {
    let l = line.lowercased()
    guard l.contains("tmux") else { return false }
    // "command not found" (bash/zsh) or "not found" (sh/dash/busybox), as a diagnostic.
    return l.contains("command not found") || l.contains("not found")
}

public func classifyTmuxLaunch(output: String) -> TmuxLaunchProbe {
    // Missing wins: a definitive shell error means tmux did not start.
    for line in output.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
        if lineIsTmuxNotFound(line) { return .tmuxMissing }
    }
    for seq in altScreenEnter where output.contains(seq) { return .tmuxStarted }
    return .inconclusive
}
