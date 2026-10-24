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

    // D-5: the Defaults Mosh group only holds settings for hosts set to Mosh.
    // A filled (even `enabled: true`, as older builds stored it) Defaults Mosh
    // config with Defaults transport unset must leave unset hosts on SSH.
    func testDefaultsMoshConfigDoesNotSwitchUnsetHostsToMosh() {
        var d = Defaults()
        d.mosh = .explicit(MoshConfig(enabled: true, serverPath: "/opt/bin/mosh-server",
                                      udpPortRange: [60000, 60010], predictionMode: .always))
        XCTAssertEqual(resolveTransport(host: host(), defaults: d), .ssh)
    }

    // D-5: the same Defaults Mosh config with `enabled: false` (what the editor
    // now writes) also leaves unset hosts on SSH.
    func testDefaultsMoshConfigDisabledKeepsSSH() {
        var d = Defaults()
        d.mosh = .explicit(MoshConfig(enabled: false, serverPath: "/opt/bin/mosh-server"))
        XCTAssertEqual(resolveTransport(host: host(), defaults: d), .ssh)
    }

    // D-5: Defaults Mosh config does not override an explicit Defaults transport.
    func testDefaultsMoshConfigWithDefaultsTransportETStaysET() {
        var d = Defaults()
        d.transport = .explicit(.et)
        d.mosh = .explicit(MoshConfig(enabled: true))
        XCTAssertEqual(resolveTransport(host: host(), defaults: d), .et)
    }

    // A host's own mosh config with enabled=false is not a legacy Mosh host.
    func testHostMoshConfigDisabledStaysSSH() {
        XCTAssertEqual(resolveTransport(host: host { $0.mosh = .explicit(MoshConfig(enabled: false)) },
                                        defaults: Defaults()), .ssh)
    }

    // Old stored data still decodes: a legacy host JSON with mosh.enabled=true and
    // no transport field still resolves to Mosh after a round-trip.
    func testLegacyMoshHostRoundTripStillMosh() throws {
        let legacy = host { $0.mosh = .explicit(MoshConfig(enabled: true, serverPath: "/usr/bin/mosh-server")) }
        let data = try JSONEncoder().encode(legacy)
        let decoded = try JSONDecoder().decode(SemicolynKit.Host.self, from: data)
        XCTAssertEqual(decoded.mosh.value?.serverPath, "/usr/bin/mosh-server")
        XCTAssertEqual(resolveTransport(host: decoded, defaults: Defaults()), .mosh)
    }
}
