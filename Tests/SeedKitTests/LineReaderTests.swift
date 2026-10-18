// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SeedKit

final class LineReaderTests: XCTestCase {
    private func split(_ chunks: [String]) -> [String] {
        var s = LineSplitter()
        var lines: [String] = []
        for c in chunks { s.feed(Array(c.utf8)) { lines.append(String($0)) } }
        s.finish { lines.append(String($0)) }
        return lines
    }

    func testLineSplitAcrossChunks() {
        XCTAssertEqual(split(["ab", "c\nde", "f\n", "g"]), ["abc", "def", "g"])
    }

    func testLastLineWithoutNewlineIsFlushed() {
        XCTAssertEqual(split(["one\ntwo"]), ["one", "two"])
    }

    func testCRLFAndBlankLinesAreSkipped() {
        XCTAssertEqual(split(["a\r\n\r\n\nb\r", "\nc"]), ["a", "b", "c"])
    }

    func testMultibyteScalarSplitAcrossChunks() {
        let bytes = Array("caf\u{e9}\n".utf8)   // e-acute is two bytes
        var s = LineSplitter()
        var lines: [String] = []
        s.feed(Array(bytes[0..<4]) ) { lines.append(String($0)) }
        s.feed(Array(bytes[4...])) { lines.append(String($0)) }
        s.finish { lines.append(String($0)) }
        XCTAssertEqual(lines, ["caf\u{e9}"])
    }

    func testEmptyInputYieldsNothing() {
        XCTAssertEqual(split([]), [])
        XCTAssertEqual(split([""]), [])
    }

    func testForEachLineSmallChunksOnRealFile() throws {
        let path = NSTemporaryDirectory() + "linereader-\(UUID().uuidString).txt"
        try "alpha\nbeta\r\ngamma".write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }
        var lines: [String] = []
        try forEachLine(inFile: path, chunkSize: 3) { lines.append(String($0)) }
        XCTAssertEqual(lines, ["alpha", "beta", "gamma"])
    }

    func testForEachLineMissingFileThrows() {
        XCTAssertThrowsError(try forEachLine(inFile: "/nonexistent/linereader-missing") { _ in }) { error in
            XCTAssertEqual((error as? CocoaError)?.code, .fileReadNoSuchFile)
        }
    }
}
