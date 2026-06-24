// Sources/GlymrKit/IO/SerialByteWriter.swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// An async destination for ordered byte chunks (e.g. an SSH shell channel).
///
/// A single conformer is driven serially by `SerialByteWriter`, so `send`
/// implementations need not be reentrancy-safe.
public protocol AsyncByteSink: Sendable {
    /// Write one chunk, suspending until the sink accepts it (back-pressure ok).
    func send(_ bytes: [UInt8]) async throws
}

/// Serializes writes to an `AsyncByteSink` in strict FIFO order.
///
/// Enqueuing is synchronous and non-blocking; a single long-lived consumer task
/// awaits each `send` fully before starting the next. This preserves ordering
/// even when the sink stalls under back-pressure — the failure mode of spawning
/// one unstructured `Task` per write, where suspended tasks can resume in any
/// order and deliver bytes out of sequence.
public final class SerialByteWriter: Sendable {
    private let continuation: AsyncStream<[UInt8]>.Continuation
    private let consumer: Task<Void, Never>

    /// - Parameters:
    ///   - sink: the destination written to one chunk at a time.
    ///   - onError: invoked with any error a `send` throws; the queue continues
    ///     with the next chunk (a failed write does not stall the stream).
    public init(sink: any AsyncByteSink, onError: (@Sendable (any Error) -> Void)? = nil) {
        let (stream, continuation) = AsyncStream<[UInt8]>.makeStream(bufferingPolicy: .unbounded)
        self.continuation = continuation
        self.consumer = Task {
            for await chunk in stream {
                do { try await sink.send(chunk) }
                catch { onError?(error) }
            }
        }
    }

    /// Append a chunk to the write queue. Returns immediately; never blocks.
    public func enqueue(_ bytes: [UInt8]) {
        continuation.yield(bytes)
    }

    /// Stop accepting new chunks. Already-queued chunks still drain.
    public func finish() {
        continuation.finish()
    }

    /// Await the consumer after `finish()` — all queued chunks have been sent.
    public func waitUntilDrained() async {
        await consumer.value
    }

    deinit {
        continuation.finish()
    }
}
