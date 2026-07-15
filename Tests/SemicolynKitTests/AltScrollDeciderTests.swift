// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class AltScrollDeciderTests: XCTestCase {
    let reg = AltScrollRegistry.bundledDefault

    private func keys(_ mode: AltScrollMode, cmd: String?, title: String? = nil) -> AltScrollKeys {
        altScrollKeys(mode: mode, paneCommand: cmd, windowTitle: title, registry: reg)
    }

    // .off is always arrows, even for a registered app.
    func testOffAlwaysArrows() {
        XCTAssertEqual(keys(.off, cmd: "claude"), .arrows)
        XCTAssertEqual(keys(.off, cmd: "bash"), .arrows)
        XCTAssertEqual(keys(.off, cmd: nil), .arrows)
    }

    // .auto: page keys for a registered tmux app, arrows otherwise / when unknown.
    func testAutoUsesCommand() {
        XCTAssertEqual(keys(.auto, cmd: "claude"), .pageKeys)
        XCTAssertEqual(keys(.auto, cmd: "bash"), .arrows)
        XCTAssertEqual(keys(.auto, cmd: nil), .arrows)   // raw/mosh: no signal -> arrows
    }

    // .auto ignores the title entirely (title only matters in .autoPlusTitle).
    func testAutoIgnoresTitle() {
        XCTAssertEqual(keys(.auto, cmd: nil, title: "claude"), .arrows)
    }

    // .alwaysPageKeys: page keys regardless of app or signal.
    func testAlwaysPageKeys() {
        XCTAssertEqual(keys(.alwaysPageKeys, cmd: "claude"), .pageKeys)
        XCTAssertEqual(keys(.alwaysPageKeys, cmd: "bash"), .pageKeys)
        XCTAssertEqual(keys(.alwaysPageKeys, cmd: nil), .pageKeys)
    }

    // .autoPlusTitle: command wins when present; falls back to title when command is nil.
    func testAutoPlusTitle() {
        XCTAssertEqual(keys(.autoPlusTitle, cmd: "claude", title: nil), .pageKeys)   // command
        XCTAssertEqual(keys(.autoPlusTitle, cmd: nil, title: "myrepo - claude: x"), .pageKeys) // title
        XCTAssertEqual(keys(.autoPlusTitle, cmd: nil, title: "vim README"), .arrows) // no match
        XCTAssertEqual(keys(.autoPlusTitle, cmd: "bash", title: "claude"), .arrows)  // command wins (no match)
    }
}
