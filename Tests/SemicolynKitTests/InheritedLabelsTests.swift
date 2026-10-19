// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// D-16: unset fields read "Default (X)" / "Default: X" with the value actually used.
final class InheritedLabelsTests: XCTestCase {
    func testLabelFormats() {
        XCTAssertEqual(defaultChoiceLabel("SSH"), "Default (SSH)")
        XCTAssertEqual(defaultPlaceholder("22"), "Default: 22")
    }

    func testBuiltInFallbacks() {
        let b = InheritedFallbacks.builtIn
        XCTAssertNil(b.user)
        XCTAssertEqual(b.port, 22)
        XCTAssertEqual(b.transport, .ssh)
        XCTAssertEqual(b.keepAliveInterval, 30)
        XCTAssertEqual(b.keepAliveRetries, 3)
        XCTAssertEqual(b.tmuxSessionName, "semicolyn")
        XCTAssertEqual(b.userPlaceholder, "e.g. ubuntu")
    }

    func testDefaultsValuesWinOverBuiltIns() {
        var d = Defaults()
        d.user = .explicit("deploy")
        d.port = .explicit(2222)
        d.transport = .explicit(.mosh)
        d.serverAliveInterval = .explicit(15)
        d.serverAliveCountMax = .explicit(6)
        d.semicolyn = .explicit(SemicolynConfig(tmux: TmuxConfig(sessionName: "work")))
        let f = InheritedFallbacks(defaults: d)
        XCTAssertEqual(f.user, "deploy")
        XCTAssertEqual(f.userPlaceholder, "Default: deploy")
        XCTAssertEqual(f.port, 2222)
        XCTAssertEqual(f.transport, .mosh)
        XCTAssertEqual(f.keepAliveInterval, 15)
        XCTAssertEqual(f.keepAliveRetries, 6)
        XCTAssertEqual(f.tmuxSessionName, "work")
    }

    func testDefaultsMoshConfigAloneDoesNotMakeTheFallbackMosh() {
        // D-5 in the editor labels: filling the Mosh group leaves "Default (SSH)".
        var d = Defaults()
        d.mosh = .explicit(MoshConfig(enabled: true, serverPath: "/x"))
        XCTAssertEqual(InheritedFallbacks(defaults: d).transport, .ssh)
    }

    func testBlankDefaultsSessionNameFallsBackToBuiltIn() {
        var d = Defaults()
        d.semicolyn = .explicit(SemicolynConfig(tmux: TmuxConfig(sessionName: "   ")))
        XCTAssertEqual(InheritedFallbacks(defaults: d).tmuxSessionName, "semicolyn")
    }

    func testMoshLocalEchoSelectionFoldsAdaptiveIntoDefault() {
        XCTAssertNil(moshLocalEchoSelection(nil))
        XCTAssertNil(moshLocalEchoSelection(.adaptive))
        XCTAssertEqual(moshLocalEchoSelection(.always), .always)
        XCTAssertEqual(moshLocalEchoSelection(.never), .never)
        XCTAssertEqual(moshLocalEchoSelection(.experimental), .experimental)
    }
}
