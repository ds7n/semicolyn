// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import GlymrKit

/// Adversarial input caps — ensures a hostile/buggy server cannot grow the
/// parser's line buffer or open-block body unboundedly (OOM protection).
final class ControlModeParserCapTests: XCTestCase {

    // MARK: - Line-length cap

    /// A single chunk of maxLineBytes+1 non-newline bytes must produce exactly
    /// one .malformed event whose reason contains "line exceeded", and the
    /// parser must resync on the next valid newline-terminated line.
    func testLineLengthCapEmitsMalformedAndResyncs() {
        let parser = ControlModeParser()
        let oversize = [UInt8](repeating: UInt8(ascii: "x"), count: ControlModeParser.maxLineBytes + 1)

        // Step 1: Feed the oversize chunk (no newline) — must be flagged.
        let events1 = parser.feed(oversize)
        XCTAssertEqual(events1.count, 1, "expected exactly one event for oversize line, got \(events1)")
        guard case let .malformed(_, reason) = events1.first else {
            return XCTFail("expected .malformed, got \(String(describing: events1.first))")
        }
        XCTAssertTrue(reason.contains("line exceeded"),
                      "reason '\(reason)' should contain 'line exceeded'")

        // Step 2: Feed a valid line — parser must resync and emit a real event.
        let events2 = parser.feed(Array("%sessions-changed\n".utf8))
        XCTAssertEqual(events2, [.sessionsChanged],
                       "parser should resync after line-length overflow")
    }

    // MARK: - Block body cap

    /// An open block with maxBlockLines+1 body lines must be closed as
    /// .malformed (not accumulated forever), and the parser must resync
    /// on the next valid notification line.
    func testBlockBodyCapEmitsMalformedAndResyncs() {
        let parser = ControlModeParser()

        // Open a block.
        _ = parser.feed(Array("%begin 1 42 0\n".utf8))

        // Feed maxBlockLines body lines — still within cap, no event yet.
        let bodyLine = Array("x\n".utf8)
        var events: [ControlModeEvent] = []
        for _ in 0..<ControlModeParser.maxBlockLines {
            events.append(contentsOf: parser.feed(bodyLine))
        }
        XCTAssertTrue(events.isEmpty,
                      "no event expected before cap is hit, got \(events)")

        // Feed the line that pushes it over the cap.
        let capEvents = parser.feed(bodyLine)
        XCTAssertEqual(capEvents.count, 1,
                       "expected exactly one event when block body cap is exceeded, got \(capEvents)")
        guard case let .malformed(_, reason) = capEvents.first else {
            return XCTFail("expected .malformed when block body cap exceeded, got \(String(describing: capEvents.first))")
        }
        XCTAssertTrue(reason.contains("block body exceeded"),
                      "malformed reason should name the block-body cap, got \(reason)")

        // Resync: a valid notification after the forced close must parse normally.
        let resyncEvents = parser.feed(Array("%sessions-changed\n".utf8))
        XCTAssertEqual(resyncEvents, [.sessionsChanged],
                       "parser should resync after block body cap overflow")
    }
}
