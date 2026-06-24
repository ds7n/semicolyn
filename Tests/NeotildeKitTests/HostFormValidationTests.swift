// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import NeotildeKit

final class HostFormValidationTests: XCTestCase {
    private func h(_ label: String = "prod", _ id: UUID = UUID(),
                   hostName: String = "h", user: Inherited<String> = .explicit("u"),
                   jump: [JumpHop] = []) -> NeotildeKit.Host {
        NeotildeKit.Host(id: id, label: label, hostName: hostName, user: user,
                      proxyJump: jump.isEmpty ? .inherit : .explicit(jump))
    }

    func testValidHostHasNoIssues() {
        let issues = validateHostForm(h(), others: [], defaults: Defaults(), passwordRefResolves: true)
        XCTAssertEqual(issues, [])
        XCTAssertTrue(canSave(issues))
    }

    func testMissingRequiredFieldsAreHardBlocks() {
        let bad = h("", hostName: "")
        let issues = validateHostForm(bad, others: [], defaults: Defaults(), passwordRefResolves: true)
        XCTAssertTrue(issues.contains { $0.kind == .missingLabel && $0.severity == .hardBlock })
        XCTAssertTrue(issues.contains { $0.kind == .missingHostName && $0.severity == .hardBlock })
        XCTAssertFalse(canSave(issues))
    }

    func testDirectCycleIsHardBlock() {
        let id = UUID()
        let host = h("self", id, jump: [.ref(hostId: id)])
        let issues = validateHostForm(host, others: [], defaults: Defaults(), passwordRefResolves: true)
        XCTAssertTrue(issues.contains { $0.kind == .jumpChainCycle && $0.severity == .hardBlock })
        XCTAssertFalse(canSave(issues))
    }

    func testInlineJumpHostEmptyHostNameIsHardBlockWithIndex() {
        let host = h("p", jump: [.inline(hostName: "", port: 22, user: nil, identities: nil)])
        let issues = validateHostForm(host, others: [], defaults: Defaults(), passwordRefResolves: true)
        XCTAssertTrue(issues.contains { $0.kind == .inlineJumpHostMissingHostName(index: 0) && $0.severity == .hardBlock })
        XCTAssertFalse(canSave(issues))
    }

    func testDuplicateLabelIsSoftBlockAndStillSavable() {
        let existing = h("prod")
        let issues = validateHostForm(h("prod"), others: [existing], defaults: Defaults(),
                                      passwordRefResolves: true)
        XCTAssertTrue(issues.contains { if case .duplicateLabel = $0.kind { return $0.severity == .softBlock }; return false })
        XCTAssertTrue(canSave(issues))   // soft → still savable
    }

    func testNoUserSoftBlockUnlessDefaultsProvides() {
        let host = h(user: .inherit)
        XCTAssertTrue(validateHostForm(host, others: [], defaults: Defaults(), passwordRefResolves: true)
            .contains { $0.kind == .noUserSet && $0.severity == .softBlock })
        // Defaults supplies a user → no issue.
        XCTAssertFalse(validateHostForm(host, others: [], defaults: Defaults(user: .explicit("root")),
                                        passwordRefResolves: true)
            .contains { $0.kind == .noUserSet })
    }

    func testStalePasswordRefIsHardBlock() {
        var host = h()
        host.passwordRef = .explicit(UUID())
        let issues = validateHostForm(host, others: [], defaults: Defaults(), passwordRefResolves: false)
        XCTAssertTrue(issues.contains { $0.kind == .stalePasswordRef && $0.severity == .hardBlock })
        XCTAssertFalse(canSave(issues))
    }

    func testPortForwardMissingFieldIsHardBlock() {
        var host = h()
        host.localForwards = .explicit([LocalForward(bindAddress: nil, bindPort: 0, hostAddress: "", hostPort: 0)])
        let issues = validateHostForm(host, others: [], defaults: Defaults(), passwordRefResolves: true)
        XCTAssertTrue(issues.contains { $0.kind == .localForwardMissingField(index: 0) && $0.severity == .hardBlock })
        XCTAssertFalse(canSave(issues))
    }

    func testRemoteForwardMissingFieldIsHardBlock() {
        var host = h()
        host.remoteForwards = .explicit([RemoteForward(bindAddress: nil, bindPort: 0, hostAddress: "", hostPort: 0)])
        let issues = validateHostForm(host, others: [], defaults: Defaults(), passwordRefResolves: true)
        XCTAssertTrue(issues.contains { $0.kind == .remoteForwardMissingField(index: 0) && $0.severity == .hardBlock })
        XCTAssertFalse(canSave(issues))
    }

    func testDynamicForwardMissingFieldIsHardBlock() {
        var host = h()
        host.dynamicForwards = .explicit([DynamicForward(bindAddress: nil, bindPort: 0)])
        let issues = validateHostForm(host, others: [], defaults: Defaults(), passwordRefResolves: true)
        XCTAssertTrue(issues.contains { $0.kind == .dynamicForwardMissingField(index: 0) && $0.severity == .hardBlock })
        XCTAssertFalse(canSave(issues))
    }
}
