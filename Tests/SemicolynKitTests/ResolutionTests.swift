// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class ResolutionTests: XCTestCase {
    // `SemicolynKit.Host` is qualified to avoid colliding with Foundation's `Host`
    // class, which is in scope transitively on Linux.
    private func host(_ b: (inout SemicolynKit.Host) -> Void = { _ in }) -> SemicolynKit.Host {
        var h = SemicolynKit.Host(id: UUID(), label: "l", hostName: "h"); b(&h); return h
    }

    func testPortPrefersHostThenDefaultsThenBuiltin() {
        XCTAssertEqual(resolvePort(host: host { $0.port = .explicit(2222) },
                                   defaults: Defaults(port: .explicit(2022))), 2222)   // host wins
        XCTAssertEqual(resolvePort(host: host(), defaults: Defaults(port: .explicit(2022))), 2022) // defaults
        XCTAssertEqual(resolvePort(host: host(), defaults: Defaults()), 22)             // builtin
    }

    func testUserThrowsWhenUnsetOnBothHostAndDefaults() {
        XCTAssertThrowsError(try resolveUser(host: host(), defaults: Defaults())) {
            XCTAssertEqual($0 as? ResolutionError, .userUnset)
        }
        XCTAssertEqual(try? resolveUser(host: host { $0.user = .explicit("deploy") },
                                        defaults: Defaults()), "deploy")
    }

    func testSecurityConservativeFallbacks() {
        XCTAssertFalse(resolveForwardAgent(host: host(), defaults: Defaults()))   // false, not inherited-true
        XCTAssertEqual(resolveStrictHostKeyChecking(host: host(), defaults: Defaults()), .acceptNew)
        XCTAssertEqual(resolvePreferredAuthentications(host: host(), defaults: Defaults()),
                       [.publicKey, .keyboardInteractive, .password])
    }

    func testCompressionAndServerAliveFallbacks() {
        XCTAssertFalse(resolveCompression(host: host(), defaults: Defaults()))
        XCTAssertTrue(resolveCompression(host: host { $0.compression = .explicit(true) }, defaults: Defaults()))
        XCTAssertEqual(resolveServerAliveInterval(host: host(), defaults: Defaults()), 30)
        XCTAssertEqual(resolveServerAliveCountMax(host: host(), defaults: Defaults()), 3)
        XCTAssertEqual(resolveServerAliveInterval(host: host(),
                                                  defaults: Defaults(serverAliveInterval: .explicit(60))), 60)
    }

    func testExplicitNoneOverridesDefaultsForListField() {
        // .explicit(nil) means "cleared to none" — must NOT fall through to Defaults.
        let h = host { $0.identities = .explicit(nil) }
        XCTAssertEqual(resolveIdentities(host: h, defaults: Defaults(identities: .explicit([UUID()]))), [])
    }

    func testListFallbacksAreEmpty() {
        XCTAssertEqual(resolveProxyJump(host: host(), defaults: Defaults()), [])
        XCTAssertEqual(resolveLocalForwards(host: host(), defaults: Defaults()), [])
        XCTAssertEqual(resolveRemoteForwards(host: host(), defaults: Defaults()), [])
        XCTAssertEqual(resolveDynamicForwards(host: host(), defaults: Defaults()), [])
    }

    func testNestedConfigLeavesResolve() {
        XCTAssertTrue(resolveMoshEnabled(host: host { $0.mosh = .explicit(MoshConfig(enabled: true)) },
                                         defaults: Defaults()))
        XCTAssertFalse(resolveMoshEnabled(host: host(), defaults: Defaults()))                 // builtin
        XCTAssertFalse(resolveTailscaleRequired(host: host(), defaults: Defaults()))
        XCTAssertFalse(resolvePredictorIncognito(host: host(), defaults: Defaults()))
        XCTAssertTrue(resolveTmuxAttemptControlMode(host: host(), defaults: Defaults()))        // builtin true
        XCTAssertFalse(resolveTmuxAttemptControlMode(
            host: host { $0.semicolyn = .explicit(SemicolynConfig(tmux: TmuxConfig(attemptControlMode: false))) },
            defaults: Defaults()))
    }

    func testOsc52AllowResolves() {
        XCTAssertTrue(resolveOsc52Allow(host: host(), defaults: Defaults()))   // builtin true
        XCTAssertFalse(resolveOsc52Allow(
            host: host { $0.semicolyn = .explicit(SemicolynConfig(osc52: Osc52Config(allow: false))) },
            defaults: Defaults()))
        XCTAssertTrue(resolveOsc52Allow(                                       // host inherits, defaults set true
            host: host(),
            defaults: Defaults(semicolyn: .explicit(SemicolynConfig(osc52: Osc52Config(allow: true))))))
    }

    // MARK: - Leaf-independent resolution (regression for the container-shadowing bug)
    //
    // A host that sets SOME leaves of a nested config must still inherit the
    // Defaults values for the leaves it leaves UNSET. The old code resolved the
    // whole container (host's explicit container won entirely), silently dropping
    // the Defaults leaves — e.g. a global "clipboard off" re-enabled by a host that
    // only toggled the predictor. Each assertion FAILS against that old behavior.

    func testHostSetsOneLeafStillInheritsDefaultsForOtherLeaves() {
        // Host sets ONLY predictor.incognito; Defaults sets osc52.allow = false.
        // The Defaults osc52 leaf must survive (old bug: builtin `true` won).
        let h = host {
            $0.semicolyn = .explicit(SemicolynConfig(predictor: PredictorConfig(incognito: true)))
        }
        let d = Defaults(semicolyn: .explicit(SemicolynConfig(osc52: Osc52Config(allow: false))))
        XCTAssertFalse(resolveOsc52Allow(host: h, defaults: d),
                       "Defaults osc52.allow=false must not be shadowed by an unrelated host leaf")
        XCTAssertTrue(resolvePredictorIncognito(host: h, defaults: d),
                      "the host's own leaf still wins")
    }

    func testHostSetsOneLeafStillInheritsDefaultsTmuxLeaf() {
        // Host sets ONLY osc52.allow; Defaults sets tmux.attemptControlMode = false.
        let h = host {
            $0.semicolyn = .explicit(SemicolynConfig(osc52: Osc52Config(allow: true)))
        }
        let d = Defaults(semicolyn: .explicit(SemicolynConfig(tmux: TmuxConfig(attemptControlMode: false))))
        XCTAssertFalse(resolveTmuxAttemptControlMode(host: h, defaults: d),
                       "Defaults tmux leaf must survive a host that only set osc52")
    }

    func testHostLeafWinsOverDefaultsLeafWhenBothSet() {
        // Both set the SAME leaf → host wins (unchanged precedence, guarded here).
        let h = host {
            $0.semicolyn = .explicit(SemicolynConfig(osc52: Osc52Config(allow: false)))
        }
        let d = Defaults(semicolyn: .explicit(SemicolynConfig(osc52: Osc52Config(allow: true))))
        XCTAssertFalse(resolveOsc52Allow(host: h, defaults: d))
    }

    func testUnsetLeafOnBothFallsToBuiltin() {
        // Host sets predictor only; neither sets osc52 → builtin `true`.
        let h = host {
            $0.semicolyn = .explicit(SemicolynConfig(predictor: PredictorConfig(incognito: true)))
        }
        let d = Defaults(semicolyn: .explicit(SemicolynConfig(predictor: PredictorConfig(incognito: false))))
        XCTAssertTrue(resolveOsc52Allow(host: h, defaults: d), "no osc52 anywhere → builtin true")
    }

    // MARK: - resolveTmuxSessionName

    func testTmuxSessionNameHostWins() {
        let h = host { $0.semicolyn = .explicit(SemicolynConfig(tmux: TmuxConfig(sessionName: "work"))) }
        let d = Defaults(semicolyn: .explicit(SemicolynConfig(tmux: TmuxConfig(sessionName: "shared"))))
        XCTAssertEqual(resolveTmuxSessionName(host: h, defaults: d), "work")
    }

    func testTmuxSessionNameInheritsDefaults() {
        let d = Defaults(semicolyn: .explicit(SemicolynConfig(tmux: TmuxConfig(sessionName: "shared"))))
        XCTAssertEqual(resolveTmuxSessionName(host: host(), defaults: d), "shared")
    }

    func testTmuxSessionNameBuiltinWhenUnset() {
        XCTAssertEqual(resolveTmuxSessionName(host: host(), defaults: Defaults()), "semicolyn")
    }

    func testTmuxSessionNameEmptyLeafFallsThrough() {
        // A host leaf set to "" (or whitespace) is treated as unset → Defaults → builtin.
        let h = host { $0.semicolyn = .explicit(SemicolynConfig(tmux: TmuxConfig(sessionName: "   "))) }
        XCTAssertEqual(resolveTmuxSessionName(host: h, defaults: Defaults()), "semicolyn")
        let h2 = host { $0.semicolyn = .explicit(SemicolynConfig(tmux: TmuxConfig(sessionName: ""))) }
        let d = Defaults(semicolyn: .explicit(SemicolynConfig(tmux: TmuxConfig(sessionName: "shared"))))
        XCTAssertEqual(resolveTmuxSessionName(host: h2, defaults: d), "shared")
    }

    func testTmuxSessionNameLeafIndependence() {
        // Host sets ONLY sessionName; Defaults sets ONLY attemptControlMode=false.
        // Each leaf resolves independently (regression for the #7 container-shadow bug).
        let h = host { $0.semicolyn = .explicit(SemicolynConfig(tmux: TmuxConfig(sessionName: "work"))) }
        let d = Defaults(semicolyn: .explicit(SemicolynConfig(tmux: TmuxConfig(attemptControlMode: false))))
        XCTAssertEqual(resolveTmuxSessionName(host: h, defaults: d), "work")
        XCTAssertFalse(resolveTmuxAttemptControlMode(host: h, defaults: d))
    }
}
