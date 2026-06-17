// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import GlymrKit

final class ModelTests: XCTestCase {
    func testHostRoundTripsThroughCodable() throws {
        let id = UUID()
        let host = Host(id: id, label: "prod-db", hostName: "db.internal",
                        port: .explicit(2222))
        let data = try JSONEncoder().encode(host)
        let decoded = try JSONDecoder().decode(Host.self, from: data)
        XCTAssertEqual(decoded, host)
    }

    func testInheritFallsBackThroughDefaultsToBuiltIn() {
        // port: host inherits → Defaults inherits → built-in fallback 22.
        let host = Host(id: UUID(), label: "h", hostName: "x", port: .inherit)
        XCTAssertEqual(resolvePort(host: host, defaults: Defaults()), 22)
    }

    func testDefaultsValueWinsOverBuiltIn() {
        let host = Host(id: UUID(), label: "h", hostName: "x", port: .inherit)
        let defaults = Defaults(port: .explicit(2200))
        XCTAssertEqual(resolvePort(host: host, defaults: defaults), 2200)
    }

    func testHostValueWinsOverDefaults() {
        let host = Host(id: UUID(), label: "h", hostName: "x", port: .explicit(22))
        let defaults = Defaults(port: .explicit(2200))
        XCTAssertEqual(resolvePort(host: host, defaults: defaults), 22)
    }

    func testCycleDetectionRefusesSelfReferentialJump() {
        let a = UUID()
        let host = Host(id: a, label: "a", hostName: "x",
                        proxyJump: .explicit([.ref(hostId: a)]))
        XCTAssertTrue(hasCycle(savingHostId: a, chain: host.resolvedJumpChain,
                               in: [a: host]))
    }
}
