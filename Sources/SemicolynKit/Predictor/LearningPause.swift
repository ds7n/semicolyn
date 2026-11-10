// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Why predictor learning is paused (privacy audit P-M6 part 2). While paused the
/// engine records and harvests nothing; suggestions still show.
///
/// Plain tmux keeps the outer terminal on the alternate screen all session, so under
/// tmux the pause is read from the window title our launch configures
/// (`tmuxTitlesFormat`); without tmux it follows the terminal's own alternate screen.
public enum LearningPause: Equatable, Sendable {
    /// The active tmux pane is on its alternate screen (vim, less, htop, ...).
    case fullScreen(command: String)
    /// The active tmux pane runs a REPL from `replCommands` (REPLs mostly stay on the
    /// normal screen, so the suffix alone misses them).
    case repl(command: String)
    /// No tmux: the terminal itself is on the alternate screen.
    case altScreen

    /// Short kind label for decision-line logging.
    public var logKind: String {
        switch self {
        case .fullScreen: return "fullScreen"
        case .repl:       return "repl"
        case .altScreen:  return "altScreen"
        }
    }

    /// The foreground command name the pause came from, nil for `.altScreen`.
    public var command: String? {
        switch self {
        case let .fullScreen(command), let .repl(command): return command
        case .altScreen: return nil
        }
    }
}

/// Appended to the tmux title while the active pane is on its alternate screen.
public let tmuxFullScreenTitleSuffix = " (full screen)"

/// The session-scoped `set-titles-string` the plain-tmux launch sets: the active pane's
/// command, plus `tmuxFullScreenTitleSuffix` while that pane is on its alternate screen.
/// The readable command comes first so a desktop terminal attached to the same session
/// still gets a sensible title.
public let tmuxTitlesFormat = "#{pane_current_command}#{?alternate_on, (full screen),}"

/// REPLs whose input is not learned, as normalized by `normalizedReplName` (so the set
/// holds `python` for `python3.12` and `sqlite` for `sqlite3`).
public let replCommands: Set<String> = [
    "python", "ipython", "bpython", "node", "deno", "bun", "irb", "pry", "ghci",
    "lua", "r", "julia", "php", "psql", "mysql", "mariadb", "sqlite", "redis-cli",
    "mongosh", "mongo", "sqlplus", "cqlsh", "clickhouse-client",
]

/// The learning pause a tmux title (OSC 0/2, in our `tmuxTitlesFormat`) asks for:
/// `.fullScreen` when it ends in `tmuxFullScreenTitleSuffix` (exact match), `.repl` when
/// the whole title is a command in `replCommands` after normalization, otherwise nil.
/// A title our format cannot produce (e.g. a program set its own) pauses nothing.
public func learningPause(forTitle title: String) -> LearningPause? {
    if title.hasSuffix(tmuxFullScreenTitleSuffix) {
        return .fullScreen(command: String(title.dropLast(tmuxFullScreenTitleSuffix.count)))
    }
    guard replCommands.contains(normalizedReplName(title)) else { return nil }
    return .repl(command: title)
}

/// The tmux title as shown in the app: `tmuxFullScreenTitleSuffix` stripped.
public func displayTitle(fromTmuxTitle title: String) -> String {
    guard title.hasSuffix(tmuxFullScreenTitleSuffix) else { return title }
    return String(title.dropLast(tmuxFullScreenTitleSuffix.count))
}

/// The pause in effect for a session. Under tmux only the title counts (the outer
/// terminal is on the alternate screen all session); without tmux only the terminal's
/// alternate screen counts (titles are not ours, so REPLs there are not detected).
public func resolvedLearningPause(tmuxAttached: Bool, titlePause: LearningPause?,
                                  alternateScreen: Bool) -> LearningPause? {
    if tmuxAttached { return titlePause }
    return alternateScreen ? .altScreen : nil
}

/// Lowercased, with trailing version characters (digits and dots) stripped:
/// `Python3.12` becomes `python`, `sqlite3` becomes `sqlite`.
private func normalizedReplName(_ command: String) -> String {
    var name = Substring(command.lowercased())
    while let last = name.last, last == "." || ("0"..."9").contains(last) {
        name = name.dropLast()
    }
    return String(name)
}
