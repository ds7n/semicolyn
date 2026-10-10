// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// The once-only, bounded decision to fall back from the Mosh direct launch to the
/// in-band launch when the direct script reports tmux missing from its PATH.
final class MoshDirectLaunchTests: XCTestCase {
    private let nonce = "Xy7Qk2Ma"
    private let markerOutput = "SEMICOLYN_LAUNCH\rSEMICOLYN_NOTMUX_Xy7Qk2Ma\r\nuser@host:~$ "

    private func input(output: String? = nil, alreadyFired: Bool = false, attached: Bool = false,
                       seconds: Double = 0.4) -> MoshDirectLaunchFallbackInput {
        MoshDirectLaunchFallbackInput(output: output ?? markerOutput, nonce: nonce,
                                      alreadyFired: alreadyFired, attached: attached,
                                      secondsSinceFirstFrame: seconds)
    }

    func testExactMarkerWithNonceFires() {
        XCTAssertTrue(shouldFireMoshDirectLaunchFallback(input()))
    }

    func testMarkerWithWrongNonceDoesNotFire() {
        XCTAssertFalse(shouldFireMoshDirectLaunchFallback(
            input(output: "SEMICOLYN_LAUNCH\rSEMICOLYN_NOTMUX_Zz9Pp1Qq\r\n$ ")))
    }

    /// e.g. this repo's source shown in a restored tmux pane.
    func testBareMarkerWithoutNonceDoesNotFire() {
        XCTAssertFalse(shouldFireMoshDirectLaunchFallback(
            input(output: #"public let marker = "SEMICOLYN_NOTMUX""# + "\r\n")))
    }

    func testNoMarkerDoesNotFire() {
        XCTAssertFalse(shouldFireMoshDirectLaunchFallback(input(output: "SEMICOLYN_LAUNCH\r\u{1b}[?1049h")))
    }

    /// Once tmux has evidently attached, even the exact marker (e.g. the user cat-ing an
    /// old log) must not type a launch line into the foreground program.
    func testAfterAttachDoesNotFire() {
        XCTAssertFalse(shouldFireMoshDirectLaunchFallback(input(attached: true)))
    }

    func testAlreadyFiredDoesNotFireAgain() {
        XCTAssertFalse(shouldFireMoshDirectLaunchFallback(input(alreadyFired: true)))
    }

    func testWindowBoundary() {
        XCTAssertEqual(moshDirectLaunchFallbackWindowSeconds, 5.0)
        XCTAssertTrue(shouldFireMoshDirectLaunchFallback(input(seconds: 0)))
        XCTAssertTrue(shouldFireMoshDirectLaunchFallback(input(seconds: 4.99)))
        XCTAssertFalse(shouldFireMoshDirectLaunchFallback(input(seconds: 5.0)))
        XCTAssertFalse(shouldFireMoshDirectLaunchFallback(input(seconds: 5.01)))
    }

    func testGeneratedNonceIsValidEightCharsAndVaries() {
        let a = makeMoshLaunchNonce()
        let b = makeMoshLaunchNonce()
        XCTAssertEqual(a.count, 8)
        XCTAssertTrue(isValidMoshLaunchNonce(a), a)
        XCTAssertTrue(isValidMoshLaunchNonce(b), b)
        XCTAssertNotEqual(a, b)   // 62^8 space: a collision here means no randomness
    }

    func testFallbackLogLineCarriesInputsAndVerdict() {
        XCTAssertEqual(moshDirectLaunchFallbackLogLine(input(seconds: 0.42), fire: true),
                       "mosh:directFallback marker=true fired=false attached=false t=0.42s → fire=true")
    }
}
