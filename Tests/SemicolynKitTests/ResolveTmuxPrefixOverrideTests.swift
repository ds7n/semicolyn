// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import XCTest
@testable import SemicolynKit

final class ResolveTmuxPrefixOverrideTests: XCTestCase {
    // `SemicolynKit.Host` is qualified to avoid colliding with Foundation's `Host`
    // class, which is in scope transitively on Linux.
    private func host(_ b: (inout SemicolynKit.Host) -> Void = { _ in }) -> SemicolynKit.Host {
        var h = SemicolynKit.Host(id: UUID(), label: "l", hostName: "h"); b(&h); return h
    }

    func testHostPrefixWins() {
        let h = host { $0.semicolyn = .explicit(SemicolynConfig(tmux: TmuxConfig(useTmux: true, prefixOverride: "C-a"))) }
        XCTAssertEqual(resolveTmuxPrefixOverride(host: h, defaults: Defaults()), "C-a")
    }

    func testDefaultsUsedWhenHostAbsent() {
        let d = Defaults(semicolyn: .explicit(SemicolynConfig(tmux: TmuxConfig(prefixOverride: "C-x"))))
        XCTAssertEqual(resolveTmuxPrefixOverride(host: host(), defaults: d), "C-x")
    }

    func testHostWinsOverDefaults() {
        let h = host { $0.semicolyn = .explicit(SemicolynConfig(tmux: TmuxConfig(prefixOverride: "C-a"))) }
        let d = Defaults(semicolyn: .explicit(SemicolynConfig(tmux: TmuxConfig(prefixOverride: "C-x"))))
        XCTAssertEqual(resolveTmuxPrefixOverride(host: h, defaults: d), "C-a")
    }

    func testAbsentEverywhereIsNil() {
        XCTAssertNil(resolveTmuxPrefixOverride(host: host(), defaults: Defaults()))
    }
}
