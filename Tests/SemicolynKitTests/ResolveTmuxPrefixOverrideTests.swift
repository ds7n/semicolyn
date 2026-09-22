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

    // learnedPrefix resolves from the HOST leaf only (learning is per-host; a
    // defaults-level learned value would be meaningless across hosts with different prefixes).
    func testLearnedPrefixFromHost() {
        let h = host { $0.semicolyn = .explicit(SemicolynConfig(tmux: TmuxConfig(useTmux: true, learnedPrefix: "C-a"))) }
        XCTAssertEqual(resolveTmuxLearnedPrefix(host: h), "C-a")
    }

    func testLearnedPrefixNilWhenAbsent() {
        XCTAssertNil(resolveTmuxLearnedPrefix(host: host()))
    }

    // A defaults-level learnedPrefix is IGNORED (host-only): learning must never leak
    // across hosts. Only the host's own learned value counts.
    func testLearnedPrefixIgnoresDefaults() {
        var h = host()
        // Even though a (nonsensical) defaults learnedPrefix exists, the host has none -> nil.
        _ = Defaults(semicolyn: .explicit(SemicolynConfig(tmux: TmuxConfig(learnedPrefix: "C-x"))))
        XCTAssertNil(resolveTmuxLearnedPrefix(host: h))
        h.semicolyn = .explicit(SemicolynConfig(tmux: TmuxConfig(learnedPrefix: "C-b")))
        XCTAssertEqual(resolveTmuxLearnedPrefix(host: h), "C-b")
    }

    func testLearnedActionKeysFromHost() {
        let h = host { $0.semicolyn = .explicit(SemicolynConfig(tmux: TmuxConfig(useTmux: true, learnedActionKeys: ["zoom": "z"]))) }
        XCTAssertEqual(resolveTmuxLearnedActionKeys(host: h)["zoom"], "z")
    }

    func testLearnedActionKeysEmptyWhenAbsent() {
        XCTAssertTrue(resolveTmuxLearnedActionKeys(host: host()).isEmpty)
    }
}
