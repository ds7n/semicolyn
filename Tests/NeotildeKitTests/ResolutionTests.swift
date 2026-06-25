// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import NeotildeKit

final class ResolutionTests: XCTestCase {
    // `NeotildeKit.Host` is qualified to avoid colliding with Foundation's `Host`
    // class, which is in scope transitively on Linux.
    private func host(_ b: (inout NeotildeKit.Host) -> Void = { _ in }) -> NeotildeKit.Host {
        var h = NeotildeKit.Host(id: UUID(), label: "l", hostName: "h"); b(&h); return h
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
            host: host { $0.neotilde = .explicit(NeotildeConfig(tmux: TmuxConfig(attemptControlMode: false))) },
            defaults: Defaults()))
    }

    func testOsc52AllowResolves() {
        XCTAssertTrue(resolveOsc52Allow(host: host(), defaults: Defaults()))   // builtin true
        XCTAssertFalse(resolveOsc52Allow(
            host: host { $0.neotilde = .explicit(NeotildeConfig(osc52: Osc52Config(allow: false))) },
            defaults: Defaults()))
        XCTAssertTrue(resolveOsc52Allow(                                       // host inherits, defaults set true
            host: host(),
            defaults: Defaults(neotilde: .explicit(NeotildeConfig(osc52: Osc52Config(allow: true))))))
    }
}
