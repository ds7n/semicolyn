// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class AltScrollDeciderTests: XCTestCase {
    let reg = AltScrollRegistry.bundledDefault

    private func decide(_ mode: AltScrollMode, cmd: String?) -> AltScrollDecision {
        altScrollDecision(mode: mode, paneCommand: cmd, windowTitle: nil, registry: reg)
    }

    // .wheel: EVERY app -> wheel, regardless of command (app-agnostic universal scroll).
    func testWheelModeAlwaysWheel() {
        for cmd in ["claude", "bash", nil] {
            let d = decide(.wheel, cmd: cmd)
            XCTAssertEqual(d.keys, .wheel, "cmd=\(cmd ?? "nil")")
            XCTAssertEqual(d.reason, "wheel")
        }
    }

    // .pageKeysArrows: registered AI-CLI -> pageKeys.
    func testFallbackRegisteredIsPageKeys() {
        let d = decide(.pageKeysArrows, cmd: "claude")
        XCTAssertEqual(d.keys, .pageKeys)
        XCTAssertEqual(d.reason, "fallback:registered")
    }
    // .pageKeysArrows: unregistered app -> arrows.
    func testFallbackUnregisteredIsArrows() {
        let d = decide(.pageKeysArrows, cmd: "bash")
        XCTAssertEqual(d.keys, .arrows)
        XCTAssertEqual(d.reason, "fallback:unregistered")
    }
    // .pageKeysArrows: nil command -> arrows (raw/mosh, no signal). NEGATIVE: not pageKeys.
    func testFallbackNilCommandIsArrows() {
        let d = decide(.pageKeysArrows, cmd: nil)
        XCTAssertEqual(d.keys, .arrows)
        XCTAssertEqual(d.reason, "fallback:unregistered")
    }

    // logLine self-contained.
    func testWheelLogLine() {
        XCTAssertEqual(decide(.wheel, cmd: "claude").logLine,
                       "mode=wheel app=claude → keys=wheel reason=wheel")
    }

    // Wrapper round-trip: altScrollKeys == altScrollDecision(...).keys for every mode.
    func testWrapperMatchesDecisionKeys() {
        for mode in AltScrollMode.allCases {
            for cmd in ["claude", "bash", nil] {
                XCTAssertEqual(
                    altScrollKeys(mode: mode, paneCommand: cmd, windowTitle: nil, registry: reg),
                    altScrollDecision(mode: mode, paneCommand: cmd, windowTitle: nil, registry: reg).keys,
                    "drift mode=\(mode) cmd=\(cmd ?? "nil")")
            }
        }
    }
}
