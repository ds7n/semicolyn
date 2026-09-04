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

/// Shell "command not found" diagnostics that name tmux. Matched by specific
/// diagnostic shapes to avoid false positives on benign warnings like
/// "tmux.conf not found" or "tmux config not found". Real shell forms:
/// - `tmux: command not found` (bash/zsh)
/// - `tmux: not found` (sh/dash/busybox)
/// - `command not found: tmux` (zsh word order)
/// These are anchored to tmux: or : tmux adjacency, so "tmux.conf not found"
/// (no colon) and "tmux config not found" do not match.
private func lineIsTmuxNotFound(_ line: Substring) -> Bool {
    let l = line.lowercased()
    return l.contains("tmux: command not found") ||
           l.contains("tmux: not found") ||
           l.contains("command not found: tmux")
}

public func classifyTmuxLaunch(output: String) -> TmuxLaunchProbe {
    // Missing wins: a definitive shell error means tmux did not start.
    for line in output.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
        if lineIsTmuxNotFound(line) { return .tmuxMissing }
    }
    for seq in altScreenEnter where output.contains(seq) { return .tmuxStarted }
    return .inconclusive
}
