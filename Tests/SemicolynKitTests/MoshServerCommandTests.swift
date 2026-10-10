// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class MoshServerCommandTests: XCTestCase {
    // The env prefix that caps an abandoned mosh-server's lifetime so a killed app
    // (UDP has no disconnect signal) does not leak a server that waits forever.
    private let tmout = "MOSH_SERVER_NETWORK_TMOUT=604800"

    // Default: no custom path, no port range. The argv starts with the network-timeout
    // env prefix so a client-less server self-reaps (mosh-server has no default timeout).
    func testDefaultCommand() {
        let cfg = MoshConfig(enabled: true)
        XCTAssertEqual(moshServerCommand(cfg),
                       [tmout, "mosh-server", "new", "-s", "-c", "256", "-l", "LANG=en_US.UTF-8"])
    }

    // Custom server path is honored (e.g. a non-PATH install); env prefix still first.
    func testCustomServerPath() {
        let cfg = MoshConfig(enabled: true, serverPath: "/opt/bin/mosh-server")
        XCTAssertEqual(moshServerCommand(cfg),
                       [tmout, "/opt/bin/mosh-server", "new", "-s", "-c", "256", "-l", "LANG=en_US.UTF-8"])
    }

    // Port range appends `-p lo:hi`.
    func testPortRangeAppended() {
        let cfg = MoshConfig(enabled: true, udpPortRange: [60000, 61000])
        XCTAssertEqual(moshServerCommand(cfg),
                       [tmout, "mosh-server", "new", "-s", "-c", "256", "-l",
                        "LANG=en_US.UTF-8", "-p", "60000:61000"])
    }

    // A malformed range (not exactly two elements) is ignored, not crashed on.
    func testMalformedPortRangeIgnored() {
        let cfg = MoshConfig(enabled: true, udpPortRange: [60000])
        XCTAssertEqual(moshServerCommand(cfg),
                       [tmout, "mosh-server", "new", "-s", "-c", "256", "-l", "LANG=en_US.UTF-8"])
    }

    // Locale override flows into the -l argument (unchanged by the env prefix).
    func testLocaleOverride() {
        let cfg = MoshConfig(enabled: true)
        XCTAssertEqual(moshServerCommand(cfg, locale: "C.UTF-8").suffix(2),
                       ["-l", "LANG=C.UTF-8"])
    }

    // The network-timeout env prefix is the FIRST argv element (a shell env assignment
    // when joined by spaces: `MOSH_SERVER_NETWORK_TMOUT=604800 mosh-server new ...`), so
    // mosh-server inherits it from its own launch environment.
    func testNetworkTimeoutEnvIsFirst() {
        let cfg = MoshConfig(enabled: true)
        XCTAssertEqual(moshServerCommand(cfg).first, tmout)
    }

    // Prediction mode is a client-side setting and must not leak into the server argv.
    func testPredictionModeAbsentFromServerArgv() {
        let cfg = MoshConfig(enabled: true, predictionMode: .adaptive)
        XCTAssertEqual(moshServerCommand(cfg),
                       [tmout, "mosh-server", "new", "-s", "-c", "256", "-l", "LANG=en_US.UTF-8"])
    }

    // A session command rides after `--` (mosh-server runs it instead of the login
    // shell). It is one already-quoted shell fragment, appended verbatim, so the joined
    // string sshd hands the login shell is exactly the bootstrap plus `-- <command>`.
    func testSessionCommandAppendedAfterDoubleDash() {
        let cfg = MoshConfig(enabled: true, udpPortRange: [60000, 61000])
        let argv = moshServerCommand(cfg, sessionCommand: "sh -c 'echo hi;exec x'")
        XCTAssertEqual(argv, [tmout, "mosh-server", "new", "-s", "-c", "256", "-l",
                              "LANG=en_US.UTF-8", "-p", "60000:61000", "--", "sh -c 'echo hi;exec x'"])
        XCTAssertEqual(argv.joined(separator: " "),
                       "MOSH_SERVER_NETWORK_TMOUT=604800 mosh-server new -s -c 256 -l LANG=en_US.UTF-8 -p 60000:61000 -- sh -c 'echo hi;exec x'")
    }

    // The real direct-launch script joins into exactly `<bootstrap> -- <script>`.
    func testDirectLaunchScriptJoinsAfterBootstrap() {
        let script = plainTmuxDirectLaunchCommand(sessionName: "semicolyn")
        let joined = moshServerCommand(MoshConfig(enabled: true), sessionCommand: script)
            .joined(separator: " ")
        XCTAssertEqual(joined, "MOSH_SERVER_NETWORK_TMOUT=604800 mosh-server new -s -c 256 -l LANG=en_US.UTF-8 -- " + script)
    }

    // nil (the default) is byte-identical to the no-command form: no trailing `--`.
    func testNilSessionCommandIsUnchanged() {
        let cfg = MoshConfig(enabled: true)
        XCTAssertEqual(moshServerCommand(cfg, sessionCommand: nil), moshServerCommand(cfg))
        XCTAssertEqual(moshServerCommand(cfg, sessionCommand: nil),
                       [tmout, "mosh-server", "new", "-s", "-c", "256", "-l", "LANG=en_US.UTF-8"])
    }
}
