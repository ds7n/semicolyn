// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
@testable import SemicolynKit

/// A deterministic `EchoOracle` fake for L1 tests. Tests set `nextCursor` and
/// `cellAt` before each sample to script exactly what the "rendered grid" shows.
/// `@unchecked Sendable` is safe: only ever touched from a single test thread.
final class ScriptedEchoOracle: EchoOracle, @unchecked Sendable {
    var nextCursor: EchoCursor? = EchoCursor(row: 0, col: 0)
    var cellAt: (Int, Int) -> EchoCell? = { _, _ in EchoCell(scalar: nil) }
    var isAlternateBuffer: Bool = false

    func cursor() -> EchoCursor? { nextCursor }
    func cell(row: Int, col: Int) -> EchoCell? { cellAt(row, col) }
}
