// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Which query produced a chip, so acceptance knows how to insert it. Set once per
/// refresh (the whole strip is one kind).
public enum SuggestionKind: Equatable, Sendable {
    case completeWord            // extends the current partial word
    case nextWordAfterPrevious   // Trigger A: current is empty, chip is a fresh next word
    case nextWordAfterCurrent    // Trigger B: current is a finished word, chip is its successor
}

/// The exact string to feed back through the input path when a chip is tapped, or nil
/// if the chip cannot be accepted. Pure; Linux-tested.
public func acceptanceInsertion(kind: SuggestionKind, current: String, chip: String) -> String? {
    guard !chip.isEmpty else { return nil }
    switch kind {
    case .completeWord:
        guard chip.hasPrefix(current) else { return nil }
        let suffix = String(chip.dropFirst(current.count))
        return suffix.isEmpty ? nil : suffix
    case .nextWordAfterPrevious:
        return chip + " "
    case .nextWordAfterCurrent:
        return " " + chip + " "
    }
}
