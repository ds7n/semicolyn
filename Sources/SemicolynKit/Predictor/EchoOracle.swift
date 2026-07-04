// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// A cursor position on the rendered terminal grid, in cell coordinates.
public struct EchoCursor: Equatable, Sendable {
    public let row: Int
    public let col: Int
    public init(row: Int, col: Int) { self.row = row; self.col = col }
}

/// The contents of one rendered grid cell. `scalar == nil` is a blank/empty cell.
public struct EchoCell: Equatable, Sendable {
    public let scalar: Unicode.Scalar?
    public init(scalar: Unicode.Scalar?) { self.scalar = scalar }
}

/// A read-only view of the *rendered* terminal grid, injected into the L1 echo
/// detector so its logic stays pure and Linux-testable. The App tier backs this
/// with SwiftTerm's `getTerminal()`; Kit tests back it with a scripted fake.
///
/// Every accessor is failable/Optional: an unavailable or drifted backing must
/// return `nil`, which the detector treats as "not echoed" (fail-safe: suppress).
public protocol EchoOracle: Sendable {
    /// The current cursor cell, or nil if unreadable.
    func cursor() -> EchoCursor?
    /// The cell at `(row, col)`, or nil if out of range / unreadable.
    func cell(row: Int, col: Int) -> EchoCell?
    /// True when the alternate screen buffer is active (full-screen TUI).
    var isAlternateBuffer: Bool { get }
}
