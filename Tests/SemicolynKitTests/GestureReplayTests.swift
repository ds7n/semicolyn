// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class GestureReplayTests: XCTestCase {
    func testReplayLineFormat() {
        let e = TouchEvent(phase: .down, point: gp(120.5, 300), time: 12.34567, touchCount: 1)
        XCTAssertEqual(e.replayLine, "touch down 120.50 300.00 12.3457 1")
    }

    func testRoundTripAllPhases() {
        for phase in [TouchPhase.down, .move, .up, .cancel] {
            let e = TouchEvent(phase: phase, point: gp(1.25, 2.5), time: 3.125, touchCount: 2)
            XCTAssertEqual(TouchEvent(replayLine: e.replayLine), e)
        }
    }

    func testParsesFromAFullDeviceLogLine() {
        let line = "2026-10-05T01:02:03.456Z 12.34  touch move 10.00 20.00 1.5000 1"
        XCTAssertEqual(TouchEvent(replayLine: line),
                       TouchEvent(phase: .move, point: gp(10, 20), time: 1.5, touchCount: 1))
    }

    func testMalformedLinesAreRejected() {
        XCTAssertNil(TouchEvent(replayLine: ""))
        XCTAssertNil(TouchEvent(replayLine: "touch down 1 2 3"))              // missing count
        XCTAssertNil(TouchEvent(replayLine: "touch hover 1 2 3 1"))           // bad phase
        XCTAssertNil(TouchEvent(replayLine: "touch down x 2 3 1"))            // bad number
        XCTAssertNil(TouchEvent(replayLine: "touch down 1 2 3 one"))          // bad count
        XCTAssertNil(TouchEvent(replayLine: "gesture:intent tap"))            // not a touch line
    }

    /// A pasted device log replays into the same intents as a scripted run (tmux tap).
    func testReplayingALogDrivesTheEngine() {
        let log = """
        x touch down 55.00 45.00 1.0000 1
        x touch up 55.00 45.00 1.1000 0
        """
        var engine = GestureEngine()
        var intents: [GestureIntent] = []
        for line in log.split(whereSeparator: \.isNewline) {
            guard let e = TouchEvent(replayLine: String(line)) else { continue }
            intents += engine.handle(e, context: gestureContext())
        }
        XCTAssertEqual(intents, [.restoreKeyboard, .tap(gc(5, 102))])
    }
}
