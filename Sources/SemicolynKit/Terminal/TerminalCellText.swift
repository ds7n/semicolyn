// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// The emulator input modes the App reads from SwiftTerm, as a copied value. The App's
/// `TerminalAccess` adapter fills it; nothing else touches the emulator for these.
public struct TerminalInputModes: Equatable, Sendable {
    /// The alternate screen buffer is active (vim, less, htop, tmux).
    public let isAlternateBuffer: Bool
    /// DECCKM: arrow keys send SS3 (`ESC O A`) instead of CSI (`ESC [ A`).
    public let applicationCursor: Bool
    /// The running application turned on any mouse-reporting mode.
    public let mouseReporting: Bool

    public init(isAlternateBuffer: Bool, applicationCursor: Bool, mouseReporting: Bool) {
        self.isAlternateBuffer = isAlternateBuffer
        self.applicationCursor = applicationCursor
        self.mouseReporting = mouseReporting
    }

    /// No terminal attached: every mode off.
    public static let unavailable = TerminalInputModes(
        isAlternateBuffer: false, applicationCursor: false, mouseReporting: false)

    /// The touch-interaction mode these modes resolve to (see `resolveMode`).
    public var interactionMode: InteractionMode {
        resolveMode(isAltScreen: isAlternateBuffer, mouseReporting: mouseReporting)
    }
}

/// The sub-word selection class of one grid cell, from its text. Empty, NUL, space and
/// tab are `.space` (an unwritten cell reads as "" or NUL depending on the SwiftTerm
/// version); a `selectionPunctuation` member is `.punct`; anything else is `.word`.
public func selectionCharClass(ofCellText text: String) -> CharClass {
    guard let ch = text.first else { return .space }
    if ch == " " || ch == "\t" || ch == "\u{0}" { return .space }
    if selectionPunctuation.contains(ch) { return .punct }
    return .word
}

/// The echo-oracle view of one grid cell, from its text: empty, NUL and space are blank
/// (`scalar == nil`); otherwise the first Unicode scalar.
public func echoCell(fromCellText text: String) -> EchoCell {
    guard let ch = text.first, ch != " ", ch != "\u{0}" else { return EchoCell(scalar: nil) }
    return EchoCell(scalar: ch.unicodeScalars.first)
}
