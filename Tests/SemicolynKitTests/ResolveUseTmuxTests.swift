// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class ResolveUseTmuxTests: XCTestCase {
    // `SemicolynKit.Host` is qualified to avoid colliding with Foundation's `Host`
    // class, which is in scope transitively on Linux.
    private func host(_ b: (inout SemicolynKit.Host) -> Void = { _ in }) -> SemicolynKit.Host {
        var h = SemicolynKit.Host(id: UUID(), label: "l", hostName: "h"); b(&h); return h
    }

    func testHostValueWins() {
        let h1 = host { $0.semicolyn = .explicit(SemicolynConfig(tmux: TmuxConfig(useTmux: false))) }
        let d1 = Defaults(semicolyn: .explicit(SemicolynConfig(tmux: TmuxConfig(useTmux: true))))
        XCTAssertFalse(resolveUseTmux(host: h1, defaults: d1))

        let h2 = host { $0.semicolyn = .explicit(SemicolynConfig(tmux: TmuxConfig(useTmux: true))) }
        let d2 = Defaults(semicolyn: .explicit(SemicolynConfig(tmux: TmuxConfig(useTmux: false))))
        XCTAssertTrue(resolveUseTmux(host: h2, defaults: d2))
    }

    func testInheritFallsToDefaults() {
        // host.semicolyn is left at .inherit (no leaf set on the host at all).
        let d = Defaults(semicolyn: .explicit(SemicolynConfig(tmux: TmuxConfig(useTmux: false))))
        XCTAssertFalse(resolveUseTmux(host: host(), defaults: d))
    }

    func testAbsentEverywhereFallsToTrue() {
        XCTAssertTrue(resolveUseTmux(host: host(), defaults: Defaults()))   // builtin fallback is true
    }
}
