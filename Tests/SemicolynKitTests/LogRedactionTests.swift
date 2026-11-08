// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
import Foundation
@testable import SemicolynKit

/// Privacy audit P-M3 / P-L4 / P-M4 D: marked values in diagnostic lines.
final class LogRedactionTests: XCTestCase {
    private let zeroSalt = Data(count: 32)
    private var shareable: LogRendering { .shareable(salt: zeroSalt) }

    private func line() -> String {
        "connect START addr=\(logHost("Example.com")) user=\(logUser("alice")) "
            + "tmux=\(logServerText("tmux 3.4"))"
    }

    // Full rendering: every value as written, no marks left.
    func testFullRenderingShowsValues() {
        XCTAssertEqual(renderLogLine(line(), .full),
                       "connect START addr=Example.com user=alice tmux=tmux 3.4")
    }

    // Shareable: hosts and users become salted tags (known HMAC-SHA256 vectors), server
    // text becomes its length, and none of the values survive.
    func testShareableRenderingReplacesValues() {
        let out = renderLogLine(line(), shareable)
        XCTAssertEqual(out, "connect START addr=host#8e35 user=user#ce38 tmux=<server text, 8 chars>")
        XCTAssertFalse(out.lowercased().contains("example"))
        XCTAssertFalse(out.contains("alice"))
    }

    // The tag ignores case, changes with the salt, and differs between hosts.
    func testTagStabilityAndSalt() {
        XCTAssertEqual(logTag("EXAMPLE.COM", kind: .host, salt: zeroSalt), "host#8e35")
        XCTAssertEqual(logTag("example.com", kind: .host, salt: Data(repeating: 1, count: 32)), "host#c276")
        XCTAssertNotEqual(logTag("example.org", kind: .host, salt: zeroSalt), "host#8e35")
    }

    // User tags keep case (Unix accounts are case-sensitive) and carry the user prefix.
    func testUserTagIsCaseSensitive() {
        XCTAssertEqual(logTag("alice", kind: .user, salt: zeroSalt), "user#ce38")
        XCTAssertEqual(logTag("Alice", kind: .user, salt: zeroSalt), "user#83fa")
        XCTAssertEqual(renderLogLine(logHost("alice"), shareable), logTag("alice", kind: .host, salt: zeroSalt))
        XCTAssertTrue(renderLogLine(logHost("alice"), shareable).hasPrefix("host#"))
    }

    // Adversarial: an open mark in unmarked text (a server value logged without a mark)
    // hides the rest of the line rather than leaking it.
    func testRawOpenMarkInUnmarkedTextFailsClosed() {
        XCTAssertEqual(renderLogLine("motd: hi\u{E004}there", shareable), "motd: hi<cut off>")
    }

    // Boundaries: an empty server text and a multi-scalar character count correctly.
    func testServerTextLengthBoundaries() {
        XCTAssertEqual(renderLogLine(logServerText(""), shareable), "<server text, 0 chars>")
        XCTAssertEqual(renderLogLine(logServerText("é👍🏽"), shareable), "<server text, 2 chars>")
    }

    // Adversarial: server text containing a close mark can't end its mark early and leak
    // what follows.
    func testValueCannotForgeCloseMark() {
        let marked = logServerText("ok\u{E005}SECRET")
        XCTAssertEqual(renderLogLine(marked, shareable), "<server text, 8 chars>")
        XCTAssertEqual(renderLogLine(marked, .full), "okSECRET")
    }

    // Adversarial: a value containing another kind's open mark can't start a nested mark.
    func testValueCannotOpenAnotherMark() {
        let marked = logHost("a\u{E004}b") + " tail"
        XCTAssertEqual(renderLogLine(marked, shareable),
                       "\(logTag("ab", kind: .host, salt: zeroSalt)) tail")
    }

    // A mark that is never closed hides the rest in a shareable rendering.
    func testUnclosedMarkFailsClosed() {
        let cut = "x \u{E000}secret.example"
        XCTAssertEqual(renderLogLine(cut, shareable), "x <cut off>")
        XCTAssertEqual(renderLogLine(cut, .full), "x secret.example")
    }

    // A stray close mark outside any value is dropped, and the text around it kept.
    func testStrayCloseMarkDropped() {
        XCTAssertEqual(renderLogLine("a\u{E001}b", shareable), "ab")
    }

    // A line with no marks is unchanged by either rendering.
    func testUnmarkedLineUnchanged() {
        XCTAssertEqual(renderLogLine("gesture:tap row=3", shareable), "gesture:tap row=3")
        XCTAssertEqual(renderLogLine("gesture:tap row=3", .full), "gesture:tap row=3")
    }

    // Only pinned TLS gets the full line.
    func testRemoteRenderingByTransport() {
        let marked = logHost("h")
        XCTAssertEqual(renderLogLine(marked, remoteLogRendering(transport: .tls, salt: zeroSalt)), "h")
        for transport in [LogTransport.tcp, .udp] {
            XCTAssertEqual(renderLogLine(marked, remoteLogRendering(transport: transport, salt: zeroSalt)),
                           logTag("h", kind: .host, salt: zeroSalt), "\(transport)")
        }
    }

    // The shareable copy uses the typed-keys-free form of a line; the full copy keeps it.
    func testShareableCopyDropsTypedKeys() {
        let entries = [
            LogEntry(line: "input(\"hunter2\")", withoutTypedKeys: "input(len=7)"),
            LogEntry(line: "host=\(logHost("example.com"))"),
        ]
        XCTAssertEqual(shareableLogText(entries, salt: zeroSalt), "input(len=7)\nhost=host#8e35")
        XCTAssertEqual(fullLogText(entries), "input(\"hunter2\")\nhost=example.com")
    }

    // The salt is created once, 32 bytes, then reused; a malformed stored salt is replaced.
    func testTagSaltCreatedOnceAndValidated() throws {
        let suite = "LogRedactionTests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = logTagSalt(in: defaults)
        XCTAssertEqual(first.count, 32)
        XCTAssertEqual(logTagSalt(in: defaults), first)

        defaults.set(Data(count: 31), forKey: logTagSaltKey)
        let replaced = logTagSalt(in: defaults)
        XCTAssertEqual(replaced.count, 32)
        XCTAssertNotEqual(replaced, Data(count: 31))
        XCTAssertEqual(defaults.data(forKey: logTagSaltKey), replaced)
    }
}
