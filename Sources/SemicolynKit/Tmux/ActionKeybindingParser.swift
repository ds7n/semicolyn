// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Parse `tmux list-keys -T prefix` output into action -> key NAME. A line looks like
/// `bind-key -T prefix <KEY> <command...>`. We match the command VERB (+ a
/// distinguishing flag for split) anywhere in the command tail, ignoring trailing
/// args, and SKIP any line whose command is a display-menu/display-popup (its nested
/// commands are not directly sendable as `prefix <key>`). First match per action wins.
public func parseActionKeybindings(_ listKeysOutput: String) -> [TmuxAction: String] {
    var map: [TmuxAction: String] = [:]
    for rawLine in listKeysOutput.split(whereSeparator: \.isNewline) {
        let line = String(rawLine)
        guard let (key, command) = bindKeyParts(line) else { continue }
        // Skip menu/popup wrappers: their inner commands are not directly sendable.
        if command.contains("display-menu") || command.contains("display-popup") { continue }
        for action in TmuxAction.allCases where map[action] == nil {
            if commandMatches(command, action) { map[action] = key }
        }
    }
    return map
}

/// Extract (keyName, commandTail) from a `bind-key -T prefix <KEY> <command...>` line.
/// Returns nil for a line that is not a prefix-table binding.
private func bindKeyParts(_ line: String) -> (key: String, command: String)? {
    let toks = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    // Expect: bind-key -T prefix <KEY> <command...>
    guard toks.count >= 5, toks[0] == "bind-key" else { return nil }
    guard let tIdx = toks.firstIndex(of: "-T"), tIdx + 1 < toks.count,
          toks[tIdx + 1] == "prefix" else { return nil }
    let keyIdx = tIdx + 2
    guard keyIdx < toks.count else { return nil }
    let key = toks[keyIdx]
    let command = toks[(keyIdx + 1)...].joined(separator: " ")
    guard !command.isEmpty else { return nil }
    return (key, command)
}

/// Whether a command tail performs `action` (verb + distinguishing flag; trailing
/// args ignored).
private func commandMatches(_ command: String, _ action: TmuxAction) -> Bool {
    func hasFlag(_ flag: String) -> Bool {
        command.split(separator: " ").contains(Substring(flag))
    }
    switch action {
    case .splitHorizontal: return command.hasPrefix("split-window") && hasFlag("-h")
    case .splitVertical:   return command.hasPrefix("split-window") && hasFlag("-v")
    case .zoom:            return command.hasPrefix("resize-pane") && hasFlag("-Z")
    case .closePane:       return command.contains("kill-pane")
    case .newWindow:       return command.hasPrefix("new-window")
    case .nextWindow:      return command.hasPrefix("next-window")
    case .previousWindow:  return command.hasPrefix("previous-window")
    case .cyclePane:       return isCyclingSelectPane(command)
    }
}

/// Whether `command` is a CYCLING `select-pane` (advance to the next pane, tmux
/// default `o` -> `select-pane -t :.+`), as opposed to a directional MOVE
/// (`-U`/`-D`/`-L`/`-R`, tmux default arrow keys) or a mark-swap (`-m`/`-M`) or
/// the last-active toggle (`-l`). Directional/mark/toggle binds are listed before
/// the cycle bind in a default config, so a plain `select-pane` prefix match would
/// grab the wrong (directional) key; this narrows to the cycling form only.
/// No `-t` at all still counts as a cycle (bare `select-pane` cycles by default).
private func isCyclingSelectPane(_ command: String) -> Bool {
    guard command.hasPrefix("select-pane") else { return false }
    let toks = command.split(separator: " ").map(String.init)
    let directionalOrMarkFlags: Set<String> = ["-U", "-D", "-L", "-R", "-l", "-m", "-M"]
    guard !toks.contains(where: directionalOrMarkFlags.contains) else { return false }
    guard let tIdx = toks.firstIndex(of: "-t") else { return true }
    guard tIdx + 1 < toks.count else { return true }
    let cyclingTargets: Set<String> = [":.+", "+", ":.-", "-"]
    return cyclingTargets.contains(toks[tIdx + 1])
}
