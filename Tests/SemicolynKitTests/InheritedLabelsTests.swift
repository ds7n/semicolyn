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
        XCTAssertFalse(b.privateMode)
        XCTAssertTrue(b.osc52Allow)
        XCTAssertEqual(b.identities, [])
    }

    func testDefaultsPrivacyAndKeyValuesFlowIntoFallbacks() {
        let key = UUID()
        var d = Defaults()
        d.semicolyn = .explicit(SemicolynConfig(predictor: PredictorConfig(incognito: true),
                                                osc52: Osc52Config(allow: false)))
        d.identities = .explicit([key])
        let f = InheritedFallbacks(defaults: d)
        XCTAssertTrue(f.privateMode)
        XCTAssertFalse(f.osc52Allow)
        XCTAssertEqual(f.identities, [key])
    }

    func testOnOffLabel() {
        XCTAssertEqual(onOffLabel(true), "On")
        XCTAssertEqual(onOffLabel(false), "Off")
        XCTAssertEqual(defaultChoiceLabel(onOffLabel(true)), "Default (On)")
    }

    // MARK: - Default SSH key (M-68)

    func testDefaultKeySelection() {
        let a = UUID(), b = UUID()
        XCTAssertNil(defaultKeySelection(.inherit))
        XCTAssertNil(defaultKeySelection(.explicit([])))
        XCTAssertNil(defaultKeySelection(.explicit(nil)))
        XCTAssertEqual(defaultKeySelection(.explicit([a, b])), a)
    }

    func testDefaultKeyIdentitiesRoundTrip() {
        let a = UUID()
        XCTAssertEqual(defaultKeyIdentities(a), .explicit([a]))
        XCTAssertEqual(defaultKeyIdentities(nil), .inherit)
        XCTAssertEqual(defaultKeySelection(defaultKeyIdentities(a)), a)
    }

    func testChosenDefaultKeyIsWhatAnUnsetHostResolves() {
        let a = UUID()
        var d = Defaults()
        d.identities = defaultKeyIdentities(a)
        let host = Host(id: UUID(), label: "h", hostName: "h")
        XCTAssertEqual(resolveIdentities(host: host, defaults: d), [a])
    }

    // MARK: - Remove a key from a host (M-69)

    func testRemovingOneOfSeveralKeysKeepsTheOthersInOrder() {
        let a = UUID(), b = UUID(), c = UUID()
        XCTAssertEqual(removingIdentity(b, from: .explicit([a, b, c])), .explicit([a, c]))
    }

    func testRemovingTheLastKeyFallsBackToDefaults() {
        let a = UUID(), d = UUID()
        let after = removingIdentity(a, from: .explicit([a]))
        XCTAssertEqual(after, .inherit)
        var defaults = Defaults()
        defaults.identities = .explicit([d])
        var host = Host(id: UUID(), label: "h", hostName: "h")
        host.identities = after
        XCTAssertEqual(resolveIdentities(host: host, defaults: defaults), [d])
    }

    func testRemovingAnUnlistedKeyChangesNothing() {
        let a = UUID(), other = UUID()
        XCTAssertEqual(removingIdentity(other, from: .explicit([a])), .explicit([a]))
        XCTAssertEqual(removingIdentity(other, from: .inherit), .inherit)
        XCTAssertEqual(removingIdentity(other, from: .explicit([])), .explicit([]))
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
