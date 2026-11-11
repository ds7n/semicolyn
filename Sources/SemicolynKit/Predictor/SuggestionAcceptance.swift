// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

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

/// Minimum width (pt) of one suggestion slot; below it the strip drops to 3 slots.
public let suggestionSlotMinWidth: Double = 90

/// How many equal-width suggestion slots fit in `width` (the space left for slots, after
/// padding and the eraser): 4 when each of four slots gets at least `suggestionSlotMinWidth`,
/// else 3. Pure.
public func suggestionSlotCount(width: Double) -> Int {
    width / 4 >= suggestionSlotMinWidth ? 4 : 3
}

/// The slot index a tap should accept, or nil when the touched slot no longer holds the
/// word that was pressed (the strip refreshed between touch-down and release). Pure.
public func acceptedSuggestionIndex(pressed: String, index: Int, current: [String]) -> Int? {
    guard current.indices.contains(index), current[index] == pressed else { return nil }
    return index
}

/// True when a refresh result is newer than the last one applied (seq 0 means unsequenced).
public func shouldApplyRefresh(seq: Int, lastApplied: Int) -> Bool {
    seq == 0 || seq > lastApplied
}
