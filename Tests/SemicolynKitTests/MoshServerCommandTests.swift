// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class MoshServerCommandTests: XCTestCase {
    // Default: no custom path, no port range → the standard bootstrap argv.
    func testDefaultCommand() {
        let cfg = MoshConfig(enabled: true)
        XCTAssertEqual(moshServerCommand(cfg),
                       ["mosh-server", "new", "-s", "-c", "256", "-l", "LANG=en_US.UTF-8"])
    }

    // Custom server path is honored (e.g. a non-PATH install).
    func testCustomServerPath() {
        let cfg = MoshConfig(enabled: true, serverPath: "/opt/bin/mosh-server")
        XCTAssertEqual(moshServerCommand(cfg),
                       ["/opt/bin/mosh-server", "new", "-s", "-c", "256", "-l", "LANG=en_US.UTF-8"])
    }

    // Port range appends `-p lo:hi`.
    func testPortRangeAppended() {
        let cfg = MoshConfig(enabled: true, udpPortRange: [60000, 61000])
        XCTAssertEqual(moshServerCommand(cfg),
                       ["mosh-server", "new", "-s", "-c", "256", "-l",
                        "LANG=en_US.UTF-8", "-p", "60000:61000"])
    }

    // A malformed range (not exactly two elements) is ignored, not crashed on.
    func testMalformedPortRangeIgnored() {
        let cfg = MoshConfig(enabled: true, udpPortRange: [60000])
        XCTAssertEqual(moshServerCommand(cfg),
                       ["mosh-server", "new", "-s", "-c", "256", "-l", "LANG=en_US.UTF-8"])
    }

    // Locale override flows into the -l argument.
    func testLocaleOverride() {
        let cfg = MoshConfig(enabled: true)
        XCTAssertEqual(moshServerCommand(cfg, locale: "C.UTF-8").suffix(2),
                       ["-l", "LANG=C.UTF-8"])
    }

    // Prediction mode is a client-side setting and must not leak into the server argv.
    func testPredictionModeAbsentFromServerArgv() {
        let cfg = MoshConfig(enabled: true, predictionMode: .adaptive)
        XCTAssertEqual(moshServerCommand(cfg),
                       ["mosh-server", "new", "-s", "-c", "256", "-l", "LANG=en_US.UTF-8"])
    }
}
