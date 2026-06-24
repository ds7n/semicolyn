// Tests/GlymrKitTests/SerialByteWriterTests.swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import GlymrKit

final class SerialByteWriterTests: XCTestCase {
    /// A sink whose first `send` stalls on a gate (simulating a backpressured
    /// channel), records each completed payload in completion order, and counts
    /// how many sends have *entered* the call.
    private actor GatedSink: AsyncByteSink {
        private var completed: [[UInt8]] = []
        private var entered = 0
        private var gate: CheckedContinuation<Void, Never>?
        private var open = false

        func send(_ bytes: [UInt8]) async throws {
            entered += 1
            if entered == 1, !open {
                await withCheckedContinuation { gate = $0 }
            }
            completed.append(bytes)
        }

        func releaseGate() { open = true; gate?.resume(); gate = nil }
        func enteredCount() -> Int { entered }
        func completedPayloads() -> [[UInt8]] { completed }
    }

    /// A sink that records every payload in completion order. Never stalls.
    private actor RecordingSink: AsyncByteSink {
        private var payloads: [[UInt8]] = []
        func send(_ bytes: [UInt8]) async throws { payloads.append(bytes) }
        func recorded() -> [[UInt8]] { payloads }
    }

    /// A sink that throws on the Nth (1-based) call; records the rest.
    private actor FlakySink: AsyncByteSink {
        struct Boom: Error {}
        private let failOn: Int
        private var count = 0
        private var delivered: [[UInt8]] = []
        init(failOn: Int) { self.failOn = failOn }
        func send(_ bytes: [UInt8]) async throws {
            count += 1
            if count == failOn { throw Boom() }
            delivered.append(bytes)
        }
        func recorded() -> [[UInt8]] { delivered }
    }

    /// Poll `cond` until true or the budget is exhausted; fail on timeout.
    private func poll(timeoutMs: Int = 2000,
                      _ cond: () async -> Bool,
                      file: StaticString = #filePath, line: UInt = #line) async throws {
        var waited = 0
        while waited < timeoutMs {
            if await cond() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
            waited += 5
        }
        XCTFail("poll timed out after \(timeoutMs)ms", file: file, line: line)
    }

    func testSerializesWritesInFifoOrderUnderStall() async throws {
        let sink = GatedSink()
        let writer = SerialByteWriter(sink: sink)

        writer.enqueue([0x41])  // A
        writer.enqueue([0x42])  // B
        writer.enqueue([0x43])  // C

        // Wait until the first send has entered and is parked on the gate.
        try await poll { await sink.enteredCount() == 1 }
        // Serialization invariant: while #1 is stalled, #2 and #3 must NOT have
        // started, and nothing has completed. (A Task-per-write impl would let
        // all three enter concurrently and overtake the stalled first write.)
        let entered = await sink.enteredCount()
        let done = await sink.completedPayloads()
        XCTAssertEqual(entered, 1, "later writes must not start until the stalled one completes")
        XCTAssertTrue(done.isEmpty, "no write may complete while the first is stalled")

        await sink.releaseGate()
        writer.finish()
        await writer.waitUntilDrained()

        let finalOrder = await sink.completedPayloads()
        XCTAssertEqual(finalOrder, [[0x41], [0x42], [0x43]])
    }

    func testDeliversAllChunksInOrderWithoutStall() async throws {
        let sink = RecordingSink()
        let writer = SerialByteWriter(sink: sink)
        for b in UInt8(0)..<10 { writer.enqueue([b]) }
        writer.finish()
        await writer.waitUntilDrained()
        let recorded = await sink.recorded()
        XCTAssertEqual(recorded, (UInt8(0)..<10).map { [$0] })
    }

    func testSendErrorIsReportedAndDoesNotStopSubsequentWrites() async throws {
        let sink = FlakySink(failOn: 2)
        let errored = Mutex<Int>(0)
        let writer = SerialByteWriter(sink: sink) { _ in errored.increment() }
        writer.enqueue([0x41])  // delivered
        writer.enqueue([0x42])  // throws
        writer.enqueue([0x43])  // still delivered after the failure
        writer.finish()
        await writer.waitUntilDrained()
        let delivered = await sink.recorded()
        XCTAssertEqual(delivered, [[0x41], [0x43]], "queue continues past a failed write")
        XCTAssertEqual(errored.value, 1, "the send error is surfaced to onError exactly once")
    }

    /// Tiny thread-safe counter for the onError assertion.
    private final class Mutex<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: T
        init(_ value: T) { stored = value }
        var value: T { lock.withLock { stored } }
        func increment() where T == Int { lock.withLock { stored += 1 } }
    }
}
