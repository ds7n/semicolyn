// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import GlymrKit

final class ThemeTests: XCTestCase {
    func testBellBronzeAccentIsBronze500() {
        XCTAssertEqual(Theme.bellBronze.accent.primary, ThemeColor("#D49A5C"))
    }

    func testSharedReferenceIsDriftProof() {
        // bell.edge and accent.primary both map to bronze500 — same value.
        XCTAssertEqual(Theme.bellBronze.bell.edge, Theme.bellBronze.accent.primary)
    }

    func testAlphaProducesOpacityVariant() {
        let promoted = Theme.bellBronze.keybar.slotBgPromoted
        XCTAssertEqual(promoted, ThemeColor("#D49A5C", opacity: 0.12))
    }

    func testRegistryContainsOnlyBellBronzeInV1() {
        XCTAssertEqual(Theme.all.count, 1)
        XCTAssertEqual(Theme.all.first, Theme.bellBronze)
    }

    func testRgbaParsesHexAndOpacity() {
        let c = ThemeColor("#D49A5C", opacity: 0.5).rgba()
        XCTAssertEqual(c.red,   Double(0xD4) / 255, accuracy: 0.0001)
        XCTAssertEqual(c.green, Double(0x9A) / 255, accuracy: 0.0001)
        XCTAssertEqual(c.blue,  Double(0x5C) / 255, accuracy: 0.0001)
        XCTAssertEqual(c.opacity, 0.5, accuracy: 0.0001)
    }
}
