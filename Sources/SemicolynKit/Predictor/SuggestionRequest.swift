// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// What the predictor strip should query for, given the current input state and the
/// result of the current-word completion attempt. Pure; Linux-tested. Mirrors the
/// `tmuxLaunchDecision`-pure pattern: the App layer feeds tracker-derived inputs and
/// acts on the returned case, so the "which word, and when" logic is testable in one place.
public enum SuggestionRequest: Equatable, Sendable {
    /// Complete the partial word `prefix` (the existing behavior).
    case completeWord(prefix: String, previous: String?)
    /// Offer next-words after `word` (bigram axis, empty next-prefix). Read-only peek.
    case nextWord(after: String)
    /// Nothing to show (clear the strip).
    case none
}

/// Decide the predictor query. Ordering matters (first match wins):
/// 1. current empty + usable previous          -> nextWord(previous)   [Trigger A, no minPrefix floor]
/// 2. current empty (no usable previous)        -> none                 [start of line]
/// 3. current non-empty + completions present   -> completeWord         [today's path]
/// 4. current non-empty + completions empty + qualifies -> nextWord(current) [Trigger B, read-only peek]
/// 5. otherwise                                 -> none
///
/// Trigger B (keying on the finished-but-uncommitted `current`) is SUPPRESSED when the
/// line is opted out or when `current` is an L4b secret-value token, so a secret's
/// existence never leaks onto the suggestion surface. Trigger A keys on the already-
/// committed `previous`, which the tracker's write path has already gated.
public func suggestionRequest(
    current: String,
    previous: String?,
    precedingToken: String?,
    currentWordCompletionsWereEmpty: Bool,
    lineOptedOut: Bool,
    minPrefix: Int
) -> SuggestionRequest {
    // Trigger A: word just committed (space), current is empty.
    if current.isEmpty {
        if let previous, !previous.isEmpty { return .nextWord(after: previous) }
        return .none
    }
    // Current-word completion path still has candidates: keep completing.
    if !currentWordCompletionsWereEmpty {
        return .completeWord(prefix: current, previous: previous)
    }
    // Trigger B: current-word ran dry. Peek next-words off the finished `current`,
    // but never off a too-short token, an opted-out line, or a secret value.
    guard current.count >= minPrefix else { return .none }
    guard !lineOptedOut else { return .none }
    guard !isSecretValueToken(current, precededBy: precedingToken) else { return .none }
    return .nextWord(after: current)
}
