// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class TransportResolutionTests: XCTestCase {
    // `SemicolynKit.Host` qualified to avoid collision with Foundation's `Host`.
    private func host(_ b: (inout SemicolynKit.Host) -> Void = { _ in }) -> SemicolynKit.Host {
        var h = SemicolynKit.Host(id: UUID(), label: "h", hostName: "h")
        b(&h)
        return h
    }

    func testHostExplicitETWins() {
        XCTAssertEqual(resolveTransport(host: host { $0.transport = .explicit(.et) }, defaults: Defaults()), .et)
    }

    func testHostExplicitSSHWins() {
        // host beats defaults
        let h = host { $0.transport = .explicit(.ssh) }
        var d = Defaults(); d.transport = .explicit(.et)
        XCTAssertEqual(resolveTransport(host: h, defaults: d), .ssh)
    }

    func testDefaultsUsedWhenHostInherits() {
        var d = Defaults(); d.transport = .explicit(.mosh)
        XCTAssertEqual(resolveTransport(host: host(), defaults: d), .mosh)
    }

    // Legacy migration: a host with mosh enabled but no transport set resolves to .mosh.
    func testLegacyMoshEnabledMigratesToMosh() {
        XCTAssertEqual(resolveTransport(host: host { $0.mosh = .explicit(MoshConfig(enabled: true)) }, defaults: Defaults()), .mosh)
    }

    // Nothing set anywhere -> SSH default.
    func testNothingSetDefaultsToSSH() {
        XCTAssertEqual(resolveTransport(host: host(), defaults: Defaults()), .ssh)
    }

    // Explicit transport beats legacy mosh (user chose SSH on a mosh-enabled host).
    func testExplicitTransportBeatsLegacyMosh() {
        let h = host {
            $0.mosh = .explicit(MoshConfig(enabled: true))
            $0.transport = .explicit(.ssh)
        }
        XCTAssertEqual(resolveTransport(host: h, defaults: Defaults()), .ssh)
    }
}
