// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// M-72 (search, duplicate) and M-73 (Connect to user@host…).
final class HostLibraryTests: XCTestCase {
    private let web = Host(id: UUID(), label: "Prod Web", hostName: "web.example.com",
                           user: .explicit("deploy"))
    private let db = Host(id: UUID(), label: "db", hostName: "10.0.0.5")
    private let home = Host(id: UUID(), label: "Home server", hostName: "nas.local",
                            user: .explicit("alice"))

    // MARK: - Search

    func testBlankQueryReturnsAllInOrder() {
        XCTAssertEqual(filterHosts([web, db, home], query: "").map(\.id), [web.id, db.id, home.id])
        XCTAssertEqual(filterHosts([web, db, home], query: "   ").map(\.id), [web.id, db.id, home.id])
    }

    func testMatchesNameCaseInsensitively() {
        XCTAssertEqual(filterHosts([web, db, home], query: "prod").map(\.id), [web.id])
        XCTAssertEqual(filterHosts([web, db, home], query: "  HOME ").map(\.id), [home.id])
    }

    func testMatchesAddress() {
        XCTAssertEqual(filterHosts([web, db, home], query: "10.0").map(\.id), [db.id])
    }

    func testMatchesOwnUser() {
        XCTAssertEqual(filterHosts([web, db, home], query: "alice").map(\.id), [home.id])
    }

    func testNoMatchIsEmpty() {
        XCTAssertEqual(filterHosts([web, db, home], query: "zzz").count, 0)
    }

    // MARK: - Duplicate

    func testDuplicateGetsNewIdCopyLabelAndNoPassword() {
        var original = web
        original.passwordRef = .explicit(original.id)
        original.transport = .explicit(.mosh)
        original.identities = .explicit([UUID()])
        let newID = UUID()
        let copy = duplicateHost(original, id: newID, existingLabels: ["Prod Web"])
        XCTAssertEqual(copy.id, newID)
        XCTAssertEqual(copy.label, "Prod Web copy")
        XCTAssertEqual(copy.passwordRef, .inherit)
        XCTAssertEqual(copy.hostName, original.hostName)
        XCTAssertEqual(copy.user, original.user)
        XCTAssertEqual(copy.transport, .explicit(.mosh))
        XCTAssertEqual(copy.identities, original.identities)
    }

    func testDuplicateKeepsEveryOtherFieldUnchanged() {
        var original = web
        original.port = .explicit(2222)
        original.serverAliveInterval = .explicit(10)
        original.semicolyn = .explicit(SemicolynConfig(tmux: TmuxConfig(sessionName: "w")))
        original.mosh = .explicit(MoshConfig(enabled: false, serverPath: "/m"))
        let copy = duplicateHost(original, id: UUID(), existingLabels: [])
        // Normalize the three fields that intentionally differ, then compare whole records.
        XCTAssertEqual(copy, original.replacingIdentity(id: copy.id, label: copy.label))
    }

    func testDuplicateLabelSkipsTakenCopies() {
        let copy = duplicateHost(db, id: UUID(), existingLabels: ["db", "db copy", "db copy 2"])
        XCTAssertEqual(copy.label, "db copy 3")
    }

    // MARK: - Quick connect parsing

    func testParsesUserHostPort() {
        XCTAssertEqual(parseQuickConnectAddress("alice@nas.local:2222"),
                       SSHConnectTarget(host: "nas.local", user: "alice", port: 2222))
    }

    func testParsesBareHostAndTrimsSpaces() {
        XCTAssertEqual(parseQuickConnectAddress("  example.com "), SSHConnectTarget(host: "example.com"))
    }

    func testParsesSSHLink() {
        XCTAssertEqual(parseQuickConnectAddress("ssh://bob@h:22"),
                       SSHConnectTarget(host: "h", user: "bob", port: 22))
    }

    func testRejectsInvalidInput() {
        XCTAssertNil(parseQuickConnectAddress(""))
        XCTAssertNil(parseQuickConnectAddress("   "))
        XCTAssertNil(parseQuickConnectAddress("alice@"))            // empty host
        XCTAssertNil(parseQuickConnectAddress("h:0"))               // port min - 1
        XCTAssertNil(parseQuickConnectAddress("h:65536"))           // port max + 1
        XCTAssertNil(parseQuickConnectAddress("h:abc"))
        XCTAssertNil(parseQuickConnectAddress("my host"))           // embedded space
        XCTAssertNil(parseQuickConnectAddress("h/path"))
        XCTAssertNil(parseQuickConnectAddress("http://h"))
    }

    func testPortBoundsAccepted() {
        XCTAssertEqual(parseQuickConnectAddress("h:1")?.port, 1)
        XCTAssertEqual(parseQuickConnectAddress("h:65535")?.port, 65535)
    }

    // MARK: - Find or create

    func testSavedHostMatchesAddressPortAndUser() {
        var withPort = web
        withPort.port = .explicit(22)
        let hosts = [db, withPort]
        XCTAssertEqual(savedHost(for: SSHConnectTarget(host: "web.example.com", user: "deploy"),
                                 in: hosts)?.id, web.id)          // unset port counts as 22
        XCTAssertNil(savedHost(for: SSHConnectTarget(host: "web.example.com", user: "other"), in: hosts))
        XCTAssertNil(savedHost(for: SSHConnectTarget(host: "web.example.com", user: "deploy", port: 2222),
                               in: hosts))
        XCTAssertEqual(savedHost(for: SSHConnectTarget(host: "10.0.0.5"), in: hosts)?.id, db.id)
    }

    func testNewHostForTarget() {
        let id = UUID()
        let h = newHost(for: SSHConnectTarget(host: "nas.local", user: "alice", port: 2200), id: id)
        XCTAssertEqual(h.id, id)
        XCTAssertEqual(h.label, "nas.local")
        XCTAssertEqual(h.hostName, "nas.local")
        XCTAssertEqual(h.user, .explicit("alice"))
        XCTAssertEqual(h.port, .explicit(2200))
        let bare = newHost(for: SSHConnectTarget(host: "h"), id: id)
        XCTAssertEqual(bare.user, .inherit)
        XCTAssertEqual(bare.port, .explicit(22))
    }
}

private extension SemicolynKit.Host {
    /// This record with a different id and label, every other field unchanged, and
    /// no password (what Duplicate should produce).
    func replacingIdentity(id: UUID, label: String) -> SemicolynKit.Host {
        var data = try! JSONEncoder().encode(self)
        var obj = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        obj["id"] = id.uuidString
        obj["label"] = label
        data = try! JSONSerialization.data(withJSONObject: obj)
        var h = try! JSONDecoder().decode(SemicolynKit.Host.self, from: data)
        h.passwordRef = .inherit
        return h
    }
}
