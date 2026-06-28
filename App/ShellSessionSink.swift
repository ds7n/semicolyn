// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import SemicolynKit
import SemicolynSSHCoreFFI

/// Bridges a UniFFI `ShellSession` to the `AsyncByteSink` seam so writes can be
/// funneled through a `SerialByteWriter` (preserving FIFO order under channel
/// back-pressure).
struct ShellSessionSink: AsyncByteSink {
    let session: ShellSession

    func send(_ bytes: [UInt8]) async throws {
        try await session.write(data: Data(bytes))
    }
}
