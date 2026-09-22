// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// How to send an action: a discovered/persisted KEY (bytes after the prefix), else
/// command-mode fallback. Precedence: session-discovered -> persisted -> command mode.
final class ActionSendTests: XCTestCase {
    func testDiscoveredKeyWins() {
        XCTAssertEqual(
            resolveActionSend(action: .splitHorizontal, discovered: "|", persisted: "%"),
            .key([0x7c]))
    }

    func testPersistedUsedWhenNoDiscovered() {
        XCTAssertEqual(
            resolveActionSend(action: .splitVertical, discovered: nil, persisted: "-"),
            .key([0x2d]))
    }

    func testCommandModeWhenNoKey() {
        XCTAssertEqual(
            resolveActionSend(action: .zoom, discovered: nil, persisted: nil),
            .commandMode("resize-pane -Z"))
    }

    // A discovered key that cannot be encoded falls through to persisted, then command mode.
    func testUnencodableDiscoveredFallsThrough() {
        XCTAssertEqual(
            resolveActionSend(action: .newWindow, discovered: "MouseDown1Pane", persisted: "c"),
            .key([0x63]))
        XCTAssertEqual(
            resolveActionSend(action: .newWindow, discovered: "MouseDown1Pane", persisted: nil),
            .commandMode("new-window"))
    }
}
