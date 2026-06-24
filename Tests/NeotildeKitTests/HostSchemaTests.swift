// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import NeotildeKit

final class HostSchemaTests: XCTestCase {
    func testFullyPopulatedHostRoundTripsThroughJSON() throws {
        let id = UUID()
        let host = Host(
            id: id, label: "prod", hostName: "db.internal",
            user: .explicit("deploy"), port: .explicit(2222),
            identities: .explicit([UUID()]),
            proxyJump: .explicit([.inline(hostName: "jump", port: 22, user: "j", identities: nil)]),
            passwordRef: .explicit(UUID()),
            localForwards: .explicit([LocalForward(bindAddress: nil, bindPort: 8080, hostAddress: "x", hostPort: 5432)]),
            remoteForwards: .inherit,
            dynamicForwards: .explicit([DynamicForward(bindAddress: nil, bindPort: 1080)]),
            serverAliveInterval: .explicit(15), serverAliveCountMax: .explicit(2),
            compression: .explicit(true),
            strictHostKeyChecking: .explicit(.acceptNew),
            forwardAgent: .explicit(false),
            preferredAuthentications: .explicit([.publicKey, .password]),
            mosh: .explicit(MoshConfig(enabled: true, serverPath: "/usr/bin/mosh-server",
                                       udpPortRange: [60000, 61000], predictionMode: .adaptive)),
            tailscale: .explicit(TailscaleConfig(required: true, tailnet: "corp.ts.net")),
            neotilde: .explicit(NeotildeConfig(predictor: PredictorConfig(incognito: true),
                                         tmux: TmuxConfig(attemptControlMode: false))))
        let data = try JSONEncoder().encode(host)
        let back = try JSONDecoder().decode(Host.self, from: data)
        XCTAssertEqual(back, host)
    }

    func testInheritExplicitNoneAndExplicitValueAreDistinctAfterRoundTrip() throws {
        // .inherit vs .explicit(nil) vs .explicit(value) must survive encoding.
        let h = Host(id: UUID(), label: "l", hostName: "h",
                     user: .inherit, port: .explicit(nil), compression: .explicit(true))
        let back = try JSONDecoder().decode(Host.self, from: JSONEncoder().encode(h))
        XCTAssertEqual(back.user, .inherit)
        XCTAssertEqual(back.port, .explicit(nil))
        XCTAssertEqual(back.compression, .explicit(true))
        XCTAssertNil(back.port.value)        // explicit-none reads as no value
    }

    func testDefaultsCarriesSameOptionalFields() throws {
        let d = Defaults(user: .explicit("root"), compression: .explicit(false),
                         strictHostKeyChecking: .explicit(.yes))
        let back = try JSONDecoder().decode(Defaults.self, from: JSONEncoder().encode(d))
        XCTAssertEqual(back, d)
    }
}
