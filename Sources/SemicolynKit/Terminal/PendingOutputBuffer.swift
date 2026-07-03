// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

/// Holds terminal output bytes that arrive before a render sink is attached, then
/// replays them in order the instant a sink attaches. This closes the "dropped
/// first frame" race on the raw/mosh terminal path: the producer (`MoshSession` /
/// the Rust PTY, via `TerminalShellOutput.onOutput`) can emit bytes synchronously
/// during connect, before SwiftUI's `makeUIView` installs the render closure. A
/// shell PTY re-emits its prompt so a dropped byte is cosmetic, but Mosh paints one
/// framebuffer diff and never replays it — so a dropped first frame leaves the
/// terminal permanently blank. This mirrors the tmux `pendingPaneBytes` replay for
/// the single, non-pane output stream.
///
/// Not thread-safe by itself: all access is expected on one actor/queue (the main
/// thread, in `TerminalShellOutput`), matching how the tmux buffer is used.
public struct PendingOutputBuffer {
    /// Bytes accumulated while no sink is attached, awaiting the next `attachSink`.
    private var pending: [UInt8] = []
    /// The current sink, or nil when detached (pre-render or post-teardown).
    private var sink: (([UInt8]) -> Void)?

    public init() {}

    /// True when nothing is buffered (used by tests + teardown assertions).
    public var isEmpty: Bool { pending.isEmpty }

    /// Deliver `bytes`: straight to the sink if one is attached, otherwise buffer
    /// them for replay when a sink next attaches. Order is preserved.
    public mutating func append(_ bytes: [UInt8]) {
        if let sink {
            sink(bytes)
        } else {
            pending.append(contentsOf: bytes)
        }
    }

    /// Attach `sink` and immediately flush any buffered bytes to it, in arrival
    /// order. With nothing pending, the sink is NOT called (no spurious empty flush).
    public mutating func attachSink(_ sink: @escaping ([UInt8]) -> Void) {
        self.sink = sink
        guard !pending.isEmpty else { return }
        let buffered = pending
        pending.removeAll()
        sink(buffered)
    }

    /// Detach the sink so subsequent `append`s re-buffer for the next sink (models
    /// the view being torn down and rebuilt).
    public mutating func detachSink() {
        sink = nil
    }
}
