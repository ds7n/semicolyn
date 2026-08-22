// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// What the predictor strip should query for, given the current input state. Pure;
/// Linux-tested. Mirrors the `tmuxLaunchDecision`-pure pattern: the App layer feeds
/// tracker-derived inputs and acts on the returned case, so the "which word, and when"
/// logic is testable in one place. The engine's `blendedSuggestions` (completions +
/// next-word successors) handles the completions-vs-next-word merge internally, so this
/// decision only needs to route, not distinguish complete-vs-next.
public enum SuggestionRequest: Equatable, Sendable {
    /// Non-empty current: show completions, plus next-word successors of `current` when
    /// `allowNextWord` (long enough, not opted-out, not a secret value). The engine blends.
    case blended(current: String, previous: String?, allowNextWord: Bool)
    /// Trigger A: current empty, offer next-words after the just-committed `previous`.
    case nextWord(after: String)
    /// Nothing to show.
    case none
}

/// Decide the predictor query. Ordering matters (first match wins):
/// 1. current empty + usable previous  -> nextWord(previous)  [Trigger A, no minPrefix floor]
/// 2. current empty (no usable previous) -> none               [start of line]
/// 3. current non-empty                -> blended               [engine merges completions + next-word]
///
/// The next-word half of `.blended` is SUPPRESSED (`allowNextWord: false`) when `current`
/// is too short, the line is opted out, or `current` is an L4b secret-value token, so a
/// secret's existence never leaks onto the suggestion surface; completions are still safe
/// and remain allowed. Trigger A keys on the already-committed `previous`, which the
/// tracker's write path has already gated.
public func suggestionRequest(current: String, previous: String?, precedingToken: String?,
                              lineOptedOut: Bool, minPrefix: Int) -> SuggestionRequest {
    if current.isEmpty {
        if let previous, !previous.isEmpty { return .nextWord(after: previous) }
        return .none
    }
    let allowNext = current.count >= minPrefix
        && !lineOptedOut
        && !isSecretValueToken(current, precededBy: precedingToken)
    return .blended(current: current, previous: previous, allowNextWord: allowNext)
}
