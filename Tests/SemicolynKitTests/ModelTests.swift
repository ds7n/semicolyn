// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

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

    func testCycleDetectionAllowsValidNonCyclicChain() {
        // The positive control: a real A→B chain where B terminates must NOT be
        // flagged. Without this, `hasCycle` could `return true` always and the
        // self-cycle test alone would still pass.
        let a = UUID(), b = UUID()
        let hostA = Host(id: a, label: "a", hostName: "x",
                         proxyJump: .explicit([.ref(hostId: b)]))
        let hostB = Host(id: b, label: "b", hostName: "y")
        XCTAssertFalse(hasCycle(savingHostId: a, chain: hostA.resolvedJumpChain,
                                in: [a: hostA, b: hostB]))
    }

    func testCycleDetectionCatchesIndirectCycle() {
        // A→B→A: the loop closes one hop removed from the saving host.
        let a = UUID(), b = UUID()
        let hostA = Host(id: a, label: "a", hostName: "x",
                         proxyJump: .explicit([.ref(hostId: b)]))
        let hostB = Host(id: b, label: "b", hostName: "y",
                         proxyJump: .explicit([.ref(hostId: a)]))
        XCTAssertTrue(hasCycle(savingHostId: a, chain: hostA.resolvedJumpChain,
                               in: [a: hostA, b: hostB]))
    }

    func testInheritIsDistinctFromExplicitNoneThroughCodable() {
        // The whole point of Inherited<T>: `.inherit` (absent → inherit) and
        // `.explicit(nil)` (explicitly cleared to none) are different states and
        // must survive serialization distinctly. If Codable collapsed them, the
        // schema's inherit-vs-none semantics would silently break.
        XCTAssertNotEqual(Inherited<Int>.inherit, .explicit(nil))

        let inheritHost = Host(id: UUID(), label: "h", hostName: "x", port: .inherit)
        let noneHost = Host(id: UUID(), label: "h", hostName: "x", port: .explicit(nil))

        let decodedInherit = try! JSONDecoder().decode(
            Host.self, from: JSONEncoder().encode(inheritHost))
        let decodedNone = try! JSONDecoder().decode(
            Host.self, from: JSONEncoder().encode(noneHost))

        XCTAssertEqual(decodedInherit.port, .inherit)
        XCTAssertEqual(decodedNone.port, .explicit(nil))
        XCTAssertNotEqual(decodedInherit.port, decodedNone.port)
    }
}
