// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class MoshConnectTests: XCTestCase {
    // Valid partition: a clean MOSH CONNECT line.
    func testParsesValidLine() {
        let out = "MOSH CONNECT 60001 x5HdELy8n2XkX9pO4dO2Zw"
        XCTAssertEqual(parseMoshConnect(out),
                       .success(port: 60001, key: "x5HdELy8n2XkX9pO4dO2Zw"))
    }

    // Valid partition: real servers print a banner/motd before the line.
    func testParsesLineAmidChatter() {
        let out = "Last login: Tue\nMOSH CONNECT 60002 AAAABBBBCCCCDDDDEEEEFF\nbye"
        XCTAssertEqual(parseMoshConnect(out),
                       .success(port: 60002, key: "AAAABBBBCCCCDDDDEEEEFF"))
    }

    // Invalid partition: no line at all.
    func testMissingLineIsNoConnectLine() {
        XCTAssertEqual(parseMoshConnect("mosh-server: command not found"),
                       .failed(.noConnectLine))
    }

    // Invalid partition: empty output.
    func testEmptyOutputIsNoConnectLine() {
        XCTAssertEqual(parseMoshConnect(""), .failed(.noConnectLine))
    }

    // Invalid partition: line present but missing the key.
    func testTruncatedLineIsMalformed() {
        XCTAssertEqual(parseMoshConnect("MOSH CONNECT 60001"),
                       .failed(.malformed("MOSH CONNECT 60001")))
    }

    // Invalid partition: non-numeric port.
    func testNonNumericPortIsMalformed() {
        XCTAssertEqual(parseMoshConnect("MOSH CONNECT abc KEYKEYKEY"),
                       .failed(.malformed("MOSH CONNECT abc KEYKEYKEY")))
    }

    // Boundary: port 0 (min-1) is out of range.
    func testPortZeroIsMalformed() {
        XCTAssertEqual(parseMoshConnect("MOSH CONNECT 0 KEYKEYKEY"),
                       .failed(.malformed("MOSH CONNECT 0 KEYKEYKEY")))
    }

    // Boundary: port 65536 (max+1) is out of range.
    func testPortAboveMaxIsMalformed() {
        XCTAssertEqual(parseMoshConnect("MOSH CONNECT 65536 KEYKEYKEY"),
                       .failed(.malformed("MOSH CONNECT 65536 KEYKEYKEY")))
    }

    // Boundary: port 65535 (max) is valid.
    func testPortMaxIsValid() {
        XCTAssertEqual(parseMoshConnect("MOSH CONNECT 65535 KEYKEYKEY"),
                       .success(port: 65535, key: "KEYKEYKEY"))
    }

    // Invalid partition: empty key after the port.
    func testEmptyKeyIsMalformed() {
        XCTAssertEqual(parseMoshConnect("MOSH CONNECT 60001 "),
                       .failed(.malformed("MOSH CONNECT 60001 ")))
    }
}
