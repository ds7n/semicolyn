// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// The scroll gesture in plain tmux with tmux's `mouse` option off: which route, and the
/// exact bytes per write.
final class TmuxScrollTests: XCTestCase {
    private let up = TmuxAction.scrollUp.gestureSequence
    private let down = TmuxAction.scrollDown.gestureSequence

    // MARK: usesTmuxScrollBinding

    /// The only partition that takes the binding: tmux on screen, no mouse reporting
    /// (tmux `mouse off`), wheel scrolling.
    func testBindingOnlyForTmuxWithMouseOffAndWheel() {
        XCTAssertTrue(usesTmuxScrollBinding(tmuxOnScreen: true, mouseReporting: false, keys: .wheel))
    }

    /// tmux `mouse on` reports the mouse to the terminal: wheel bytes work, keep them.
    func testMouseOnKeepsWheelBytes() {
        XCTAssertFalse(usesTmuxScrollBinding(tmuxOnScreen: true, mouseReporting: true, keys: .wheel))
    }

    /// The user's arrow-key fallback setting is honored as-is.
    func testArrowFallbackKeepsArrows() {
        XCTAssertFalse(usesTmuxScrollBinding(tmuxOnScreen: true, mouseReporting: false, keys: .arrows))
    }

    /// No tmux on screen (raw shell app, detached tmux): never the tmux binding.
    func testNoTmuxNeverUsesBinding() {
        XCTAssertFalse(usesTmuxScrollBinding(tmuxOnScreen: false, mouseReporting: false, keys: .wheel))
        XCTAssertFalse(usesTmuxScrollBinding(tmuxOnScreen: false, mouseReporting: true, keys: .wheel))
    }

    // MARK: plainTmuxScrollBytes

    func testZeroLinesSendsNothing() {
        XCTAssertEqual(plainTmuxScrollBytes(lines: 0), [])
    }

    /// Positive = finger down = older history = scroll-up sequence.
    func testOneLineOlderIsOneScrollUp() {
        XCTAssertEqual(plainTmuxScrollBytes(lines: 1), up)
    }

    func testOneLineNewerIsOneScrollDown() {
        XCTAssertEqual(plainTmuxScrollBytes(lines: -1), down)
    }

    func testTwoLinesAreTwoSequences() {
        XCTAssertEqual(plainTmuxScrollBytes(lines: 2), up + up)
        XCTAssertEqual(plainTmuxScrollBytes(lines: -2), down + down)
    }

    /// tmux skips bindings from the third key that arrives together (assume-paste-time),
    /// so a write never carries more than two.
    func testThreeOrMoreLinesCapAtTwoSequences() {
        XCTAssertEqual(plainTmuxScrollBytes(lines: 3), up + up)
        XCTAssertEqual(plainTmuxScrollBytes(lines: -40), down + down)
        XCTAssertEqual(plainTmuxScrollBytes(lines: .max), up + up)
        XCTAssertEqual(plainTmuxScrollBytes(lines: .min), down + down)
    }
}
