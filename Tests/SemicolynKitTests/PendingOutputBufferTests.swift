// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// The buffer that stops early terminal output (notably Mosh's one-shot first
/// framebuffer diff) from being dropped when it arrives before the render closure
/// is installed. Mirrors the tmux `pendingPaneBytes` replay, but for the single
/// raw/mosh output stream. Pure so the accumulate/flush ordering is Linux-tested.
final class PendingOutputBufferTests: XCTestCase {
    // Bytes that arrive BEFORE a sink is attached are held, then delivered in order
    // the instant the sink attaches. This is the regression: Mosh's first frame.
    func testBytesBeforeSinkAreBufferedThenFlushedInOrder() {
        var buffer = PendingOutputBuffer()
        buffer.append([1, 2, 3])
        buffer.append([4, 5])
        var delivered: [UInt8] = []
        buffer.attachSink { delivered.append(contentsOf: $0) }
        XCTAssertEqual(delivered, [1, 2, 3, 4, 5])
    }

    // After the sink is attached, the buffer holds nothing (it was flushed).
    func testBufferIsEmptyAfterFlush() {
        var buffer = PendingOutputBuffer()
        buffer.append([9])
        buffer.attachSink { _ in }
        XCTAssertTrue(buffer.isEmpty, "flushing the sink must drain the pending buffer")
    }

    // Bytes that arrive AFTER the sink is attached go straight through, not buffered.
    func testBytesAfterSinkPassThroughImmediately() {
        var buffer = PendingOutputBuffer()
        var delivered: [UInt8] = []
        buffer.attachSink { delivered.append(contentsOf: $0) }
        buffer.append([7, 8])
        XCTAssertEqual(delivered, [7, 8])
        XCTAssertTrue(buffer.isEmpty, "post-attach bytes are forwarded, never retained")
    }

    // Attaching with nothing pending delivers nothing (no spurious empty flush).
    func testAttachWithNothingPendingDeliversNothing() {
        var buffer = PendingOutputBuffer()
        var callCount = 0
        buffer.attachSink { _ in callCount += 1 }
        XCTAssertEqual(callCount, 0, "no pending bytes → the sink is not called on attach")
    }

    // Detaching re-buffers: bytes arriving while detached are held for the next sink
    // (models the view being torn down and a new one installing its closure).
    func testDetachThenReattachBuffersInterimBytes() {
        var buffer = PendingOutputBuffer()
        buffer.attachSink { _ in }
        buffer.detachSink()
        buffer.append([42])
        var delivered: [UInt8] = []
        buffer.attachSink { delivered.append(contentsOf: $0) }
        XCTAssertEqual(delivered, [42], "bytes during a detached window are replayed to the next sink")
    }
}
