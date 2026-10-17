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

/// What a chip tap sends: `backspaces` DELs followed by `text`.
public struct AcceptanceEdit: Equatable, Sendable {
    public let backspaces: Int
    public let text: String

    public init(backspaces: Int, text: String) {
        self.backspaces = backspaces
        self.text = text
    }
}

/// The edit for accepting `suggestion` against the current `line`, or nil when the chip no
/// longer applies (line moved on, trailing punctuation, nothing to add or correct). Pure.
public func acceptanceEdit(for suggestion: Suggestion, line: String) -> AcceptanceEdit? {
    let token = lineContext(line: line, isKnownTool: { _ in false }).currentToken
    let shape = lookupWord(fromToken: token)
    guard shape.trailing.isEmpty else { return nil }
    let typed = shape.word
    let text = suggestion.text
    guard !text.isEmpty else { return nil }
    let space = (text.hasSuffix("/") || text.hasSuffix("=")) ? "" : " "

    switch suggestion.kind {
    case .completion:
        if text.hasPrefix(typed) {
            let suffix = String(text.dropFirst(typed.count))
            return suffix.isEmpty ? nil : AcceptanceEdit(backspaces: 0, text: suffix + space)
        }
        guard text.lowercased().hasPrefix(typed.lowercased()) else { return nil }
        return AcceptanceEdit(backspaces: typed.count, text: text + space)
    case .correction:
        guard !typed.isEmpty else { return nil }
        return AcceptanceEdit(backspaces: typed.count, text: text + space)
    case .nextWord:
        let lead = typed.isEmpty ? "" : " "
        return AcceptanceEdit(backspaces: 0, text: lead + text + space)
    }
}

/// Keystrokes the user avoided by tapping instead of typing: the edit's length minus the tap.
public func keystrokesSaved(_ edit: AcceptanceEdit) -> Int {
    edit.backspaces + edit.text.count - 1
}

/// How many chips fit in `available` width (chips separated by `spacing`). The first chip
/// always shows (the App truncates it); 0 only when there are no chips.
public func chipsThatFit(widths: [Double], available: Double, spacing: Double) -> Int {
    guard !widths.isEmpty else { return 0 }
    var used = 0.0
    var count = 0
    for width in widths {
        let next = count == 0 ? width : used + spacing + width
        if next > available { break }
        used = next
        count += 1
    }
    return max(count, 1)
}

/// True when a refresh result is newer than the last one applied (seq 0 means unsequenced).
public func shouldApplyRefresh(seq: Int, lastApplied: Int) -> Bool {
    seq == 0 || seq > lastApplied
}
