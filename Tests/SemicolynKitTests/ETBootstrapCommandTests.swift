// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class ETBootstrapCommandTests: XCTestCase {
    func testDefaultCommand() {
        let cmd = etBootstrapCommand(id: "XXX0123456789ab",
                                     passkey: "0123456789abcdef0123456789abcdef",
                                     term: "xterm-256color")
        XCTAssertEqual(cmd,
            "echo 'XXX0123456789ab/0123456789abcdef0123456789abcdef_xterm-256color' | etterminal --verbose=0")
    }

    func testVerboseLevelAppears() {
        let cmd = etBootstrapCommand(id: "XXXa", passkey: "p", term: "xterm", verbose: 3)
        XCTAssertEqual(cmd, "echo 'XXXa/p_xterm' | etterminal --verbose=3")
    }

    func testCustomEtterminalPath() {
        let cmd = etBootstrapCommand(id: "XXXa", passkey: "p", term: "xterm",
                                     etterminalPath: "/opt/bin/etterminal")
        XCTAssertEqual(cmd, "echo 'XXXa/p_xterm' | /opt/bin/etterminal --verbose=0")
    }

    func testKillUserPrefix() {
        let cmd = etBootstrapCommand(id: "XXXa", passkey: "p", term: "xterm", killUser: "alice")
        XCTAssertEqual(cmd,
            "pkill etterminal -u alice; sleep 0.5; echo 'XXXa/p_xterm' | etterminal --verbose=0")
    }
}
