// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import SemicolynKit

/// Bridges an `ETSession` to the `AsyncByteSink` seam so a `TmuxRuntime` can
/// drive its control-mode writes over ET, exactly as `ShellSessionSink` does over
/// SSH. This is what makes native `tmux -CC` panes work on the ET transport:
/// `TmuxRuntime.setWriteSink(ETSessionSink(session:))` routes `send-keys` /
/// `refresh-client` (and the in-band launch) into the ET stream.
///
/// `ETSession.send` is already serialized on the session's own private queue, so
/// this `send` need only marshal the chunk; `SerialByteWriter` still fronts it to
/// preserve strict FIFO ordering across chunks (matching the SSH path).
///
/// `@unchecked Sendable`: `AsyncByteSink` is `Sendable`, and `SerialByteWriter`
/// runs this `send` on its consumer task (off the main actor). `ETSession` is a
/// bare `NSObject` (not `Sendable`), but the ONLY method reached across that
/// boundary is `-send:`, which the class marshals onto its own private serial
/// queue, so the cross-thread call is safe. The mutable callback properties
/// (`onOutput`, …) are set once on the main actor at attach and never touched
/// here, so this narrow unchecked claim is sound.
struct ETSessionSink: @unchecked Sendable, AsyncByteSink {
    let session: ETSession

    func send(_ bytes: [UInt8]) async throws {
        session.send(Data(bytes))
    }
}
