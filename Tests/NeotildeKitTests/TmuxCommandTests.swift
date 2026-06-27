// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import NeotildeKit

/// Encoder for outbound tmux control-mode command lines. Per
/// `2026-06-20-tmux-command-encoder-design`: pure value-in/string-out, fail-closed
/// on invalid input, never emits a framing newline.
final class TmuxCommandTests: XCTestCase {
    // MARK: new-window / select / kill (ID-only, structural)

    func testNewWindow() {
        XCTAssertEqual(TmuxCommand.newWindow(), "new-window")
    }

    func testSelectWindowRendersAtSigil() {
        XCTAssertEqual(TmuxCommand.selectWindow(target: WindowID(raw: 3)), "select-window -t @3")
    }

    func testSelectPaneRendersPercentSigil() {
        XCTAssertEqual(TmuxCommand.selectPane(target: PaneID(raw: 7)), "select-pane -t %7")
    }

    func testKillPane() {
        XCTAssertEqual(TmuxCommand.killPane(target: PaneID(raw: 0)), "kill-pane -t %0")
    }

    func testKillWindowRendersAtSigil() {
        XCTAssertEqual(TmuxCommand.killWindow(target: WindowID(raw: 2)), "kill-window -t @2")
    }

    func testSelectNextPaneUsesPlusTarget() {
        XCTAssertEqual(TmuxCommand.selectPaneRelative(next: true), "select-pane -t +")
    }

    func testSelectPrevPaneUsesMinusTarget() {
        XCTAssertEqual(TmuxCommand.selectPaneRelative(next: false), "select-pane -t -")
    }

    func testZoomPaneUsesResizeZ() {
        XCTAssertEqual(TmuxCommand.zoomPane(target: PaneID(raw: 4)), "resize-pane -Z -t %4")
    }

    // MARK: split-window — divider-naming → tmux flag

    func testSplitSideBySideUsesHorizontalFlag() {
        // .sideBySide = vertical divider, new pane to the right = tmux -h
        XCTAssertEqual(TmuxCommand.splitWindow(target: PaneID(raw: 2), direction: .sideBySide),
                       "split-window -h -t %2")
    }

    func testSplitStackedUsesVerticalFlag() {
        // .stacked = horizontal divider, new pane below = tmux -v
        XCTAssertEqual(TmuxCommand.splitWindow(target: PaneID(raw: 2), direction: .stacked),
                       "split-window -v -t %2")
    }

    // MARK: resize-pane — BVA on dimensions

    func testResizeValidDimensions() {
        XCTAssertEqual(TmuxCommand.resizePane(target: PaneID(raw: 1), width: 80, height: 24),
                       "resize-pane -t %1 -x 80 -y 24")
    }

    func testResizeMinimumOneByOne() { // min valid
        XCTAssertEqual(TmuxCommand.resizePane(target: PaneID(raw: 1), width: 1, height: 1),
                       "resize-pane -t %1 -x 1 -y 1")
    }

    func testResizeZeroWidthRejected() { // min-1
        XCTAssertNil(TmuxCommand.resizePane(target: PaneID(raw: 1), width: 0, height: 24))
    }

    func testResizeNegativeHeightRejected() {
        XCTAssertNil(TmuxCommand.resizePane(target: PaneID(raw: 1), width: 80, height: -5))
    }

    // MARK: send-keys — hex encoding (security-critical)

    func testSendKeysEncodesAsciiAsLowercaseHex() {
        // "rm" = 0x72 0x6d
        XCTAssertEqual(TmuxCommand.sendKeys(target: PaneID(raw: 0), bytes: Array("rm".utf8)),
                       "send-keys -t %0 -H 72 6d")
    }

    func testSendKeysEncodesControlBytes() {
        // Esc (0x1b) then Ctrl-C (0x03)
        XCTAssertEqual(TmuxCommand.sendKeys(target: PaneID(raw: 5), bytes: [0x1b, 0x03]),
                       "send-keys -t %5 -H 1b 03")
    }

    func testSendKeysZeroPadsSingleDigitBytes() {
        // 0x00, 0x09, 0x0f must be 00 09 0f — not 0 9 f
        XCTAssertEqual(TmuxCommand.sendKeys(target: PaneID(raw: 1), bytes: [0x00, 0x09, 0x0f]),
                       "send-keys -t %1 -H 00 09 0f")
    }

    func testSendKeysEncodesNewlineAndCarriageReturnAsHex() {
        // Adversarial: the two framing bytes must round-trip as hex, never appear literally.
        let cmd = TmuxCommand.sendKeys(target: PaneID(raw: 1), bytes: [0x0a, 0x0d])
        XCTAssertEqual(cmd, "send-keys -t %1 -H 0a 0d")
        XCTAssertFalse(cmd!.contains("\n"), "framing newline must never appear in output")
        XCTAssertFalse(cmd!.contains("\r"))
    }

    func testSendKeysEncodesMultibyteUtf8() {
        // "é" = U+00E9 = 0xC3 0xA9 in UTF-8
        XCTAssertEqual(TmuxCommand.sendKeys(target: PaneID(raw: 2), bytes: Array("é".utf8)),
                       "send-keys -t %2 -H c3 a9")
    }

    func testSendKeysHighByte() {
        XCTAssertEqual(TmuxCommand.sendKeys(target: PaneID(raw: 0), bytes: [0xff]),
                       "send-keys -t %0 -H ff")
    }

    func testSendKeysEmptyBytesRejected() { // boundary: no-op send is a caller bug
        XCTAssertNil(TmuxCommand.sendKeys(target: PaneID(raw: 0), bytes: []))
    }

    // MARK: kill-session — name charset validation (fail-closed)

    func testKillSessionValidNeotildeName() {
        XCTAssertEqual(TmuxCommand.killSession(name: "neotilde-a3f7c2e9"),
                       "kill-session -t neotilde-a3f7c2e9")
    }

    func testKillSessionValidAltName() {
        XCTAssertEqual(TmuxCommand.killSession(name: "neotilde-a3f7c2e9-1b4d"),
                       "kill-session -t neotilde-a3f7c2e9-1b4d")
    }

    func testKillSessionEmptyNameRejected() {
        XCTAssertNil(TmuxCommand.killSession(name: ""))
    }

    func testKillSessionRejectsWhitespace() { // injection vector: arg split
        XCTAssertNil(TmuxCommand.killSession(name: "neotilde foo"))
    }

    func testKillSessionRejectsSemicolonInjection() { // ; chains a second command
        XCTAssertNil(TmuxCommand.killSession(name: "x; kill-server"))
    }

    func testKillSessionRejectsNewlineInjection() { // newline = new command line
        XCTAssertNil(TmuxCommand.killSession(name: "x\nkill-server"))
    }

    func testKillSessionRejectsUppercase() { // charset is [a-z0-9-]
        XCTAssertNil(TmuxCommand.killSession(name: "Neotilde-ABCD"))
    }

    // MARK: refresh-client -C — control-mode resize (BVA on dimensions)

    func testRefreshClientSizeEncodesAndGuards() {
        XCTAssertEqual(TmuxCommand.refreshClientSize(width: 80, height: 24), "refresh-client -C 80x24")
        XCTAssertEqual(TmuxCommand.refreshClientSize(width: 1, height: 1), "refresh-client -C 1x1")  // min
        XCTAssertNil(TmuxCommand.refreshClientSize(width: 0, height: 24))                              // min-1
        XCTAssertNil(TmuxCommand.refreshClientSize(width: 80, height: 0))
        XCTAssertNil(TmuxCommand.refreshClientSize(width: -5, height: 24))
    }

    func testListPaneCommandsFormat() {
        XCTAssertEqual(TmuxCommand.listPaneCommands(),
                       "list-panes -a -F \"#{pane_id} #{pane_current_command}\"")
        // Framing-safe: never contains a raw newline/carriage return.
        XCTAssertFalse(TmuxCommand.listPaneCommands().contains("\n"))
        XCTAssertFalse(TmuxCommand.listPaneCommands().contains("\r"))
    }
}
