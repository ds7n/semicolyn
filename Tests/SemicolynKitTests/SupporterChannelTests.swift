// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class SupporterChannelTests: XCTestCase {
    func testItemsVisibleOnlyOnDebugAndTestFlight() {
        XCTAssertTrue(supporterItemsVisible(.debug))
        XCTAssertTrue(supporterItemsVisible(.testFlight))
        XCTAssertFalse(supporterItemsVisible(.appStore))
        XCTAssertFalse(supporterItemsVisible(.unknown))
    }

    func testUnlockMatrix() {
        // (channel, previewOn, purchased) -> unlocked, written out literally.
        let table: [(BuildChannel, Bool, Bool, Bool)] = [
            (.debug, false, false, false),
            (.debug, true, false, true),
            (.debug, false, true, true),
            (.debug, true, true, true),
            (.testFlight, false, false, false),
            (.testFlight, true, false, true),
            (.testFlight, false, true, true),
            (.testFlight, true, true, true),
            (.appStore, false, false, false),
            (.appStore, true, false, false),
            (.appStore, false, true, true),
            (.appStore, true, true, true),
            (.unknown, false, false, false),
            (.unknown, true, false, false),
            (.unknown, false, true, true),
            (.unknown, true, true, true),
        ]
        XCTAssertEqual(table.count, 16)
        for (channel, preview, purchased, expected) in table {
            XCTAssertEqual(supporterUnlocked(channel: channel, previewOn: preview, purchased: purchased),
                           expected, "\(channel) preview=\(preview) purchased=\(purchased)")
        }
    }

    func testAppStoreChannelNeverUnlocksEvenWithPreviewOn() {
        XCTAssertFalse(supporterUnlocked(channel: .appStore, previewOn: true, purchased: false))
        XCTAssertFalse(supporterUnlocked(channel: .unknown, previewOn: true, purchased: false))
    }

    func testVisibleThemesAppStoreListsOnlyFree() {
        XCTAssertEqual(visibleThemes(channel: .appStore).map(\.id.raw), ["neonMidnight"])
        XCTAssertEqual(visibleThemes(channel: .unknown).map(\.id.raw), ["neonMidnight"])
    }

    func testVisibleThemesTestFlightListsAllInOrder() {
        XCTAssertEqual(visibleThemes(channel: .testFlight).map(\.id.raw),
                       ["neonMidnight", "bellBronze", "neonCobalt", "glacier"])
        XCTAssertEqual(visibleThemes(channel: .debug).map(\.id.raw),
                       ["neonMidnight", "bellBronze", "neonCobalt", "glacier"])
    }
}
