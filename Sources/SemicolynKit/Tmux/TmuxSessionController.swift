// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Where a controlled session is in its lifecycle.
public enum TmuxLifecycle: Equatable, Sendable {
    case idle
    case attaching
    case attached
    case exited(reason: String?)
}

/// A command handed to the channel: its correlation `id` and the framed bytes to
/// write (the encoder line plus exactly one `\n`).
public struct TmuxSubmission: Equatable, Sendable {
    public let id: UInt64
    public let wire: [UInt8]
    public init(id: UInt64, wire: [UInt8]) {
        self.id = id
        self.wire = wire
    }
}

/// A submitted command whose `%begin`/`%end`/`%error` result block has arrived.
public struct ResolvedCommand: Equatable, Sendable {
    public let id: UInt64
    public let outcome: CommandOutcome
    public init(id: UInt64, outcome: CommandOutcome) {
        self.id = id
        self.outcome = outcome
    }
}

/// What changed as a result of one ``TmuxSessionController/feed(_:)`` call.
public struct TmuxControllerOutput: Equatable, Sendable {
    public var lifecycleChanged: Bool
    public var stateChanged: Bool
    public var resolved: [ResolvedCommand]
    /// Pane output decoded during this feed, in arrival order. Empty when none.
    public var paneOutput: [PaneOutputChunk]
    /// Commands the runtime must send because this feed crossed
    /// `.attaching → .attached`. Empty except on that one edge — fires once.
    /// See the attach-layout-prime design.
    public var attachedPrimeCommands: [String]
    public init(lifecycleChanged: Bool, stateChanged: Bool,
                resolved: [ResolvedCommand], paneOutput: [PaneOutputChunk],
                attachedPrimeCommands: [String] = []) {
        self.lifecycleChanged = lifecycleChanged
        self.stateChanged = stateChanged
        self.resolved = resolved
        self.paneOutput = paneOutput
        self.attachedPrimeCommands = attachedPrimeCommands
    }
}

/// A decoded `%output` chunk: the pane it belongs to and its raw bytes.
public struct PaneOutputChunk: Equatable, Sendable {
    public let pane: PaneID
    public let data: [UInt8]
    public init(pane: PaneID, data: [UInt8]) {
        self.pane = pane
        self.data = data
    }
}

/// Drives a `tmux -CC` control-mode session from attach to exit by tying together
/// the parser (bytes → events), the session model (events → renderable state),
/// and the command encoder (intents → lines). A **pure state machine with no
/// I/O**: ``start(sessionName:)`` yields the exec string to run on the channel,
/// ``feed(_:)`` consumes channel bytes, and ``submit(_:)`` frames a command for
/// the caller to write. See `2026-06-20-tmux-session-controller-design`.
public final class TmuxSessionController {
    /// Lifecycle the caller observes: `.idle → .attaching → .attached → .exited`.
    public private(set) var lifecycle: TmuxLifecycle = .idle
    /// The renderable session model, folded from inbound events.
    public private(set) var state = TmuxSessionState()

    private let parser = ControlModeParser()
    private var pending: [UInt64] = []   // FIFO of submitted command ids awaiting a result block
    private var nextID: UInt64 = 0

    public init() {}

    /// Begin a session named `sessionName`. Returns the SSH exec command string —
    /// `tmux -CC new-session -A -s <name>` (atomic create-or-attach, shared per the
    /// session-naming spec) — that the caller runs on the channel. Returns nil if
    /// the name is invalid or the controller has already started.
    public func start(sessionName: String) -> String? {
        guard lifecycle == .idle, isValidTmuxSessionName(sessionName) else { return nil }
        lifecycle = .attaching
        return "tmux -CC new-session -A -s \(sessionName)"
    }

    /// Register `commandLine` (an encoder output) for correlation and return its
    /// id plus the framed wire bytes (`line` + `\n`). Returns nil unless attached.
    public func submit(_ commandLine: String) -> TmuxSubmission? {
        guard lifecycle == .attached else { return nil }
        let id = nextID
        nextID += 1
        pending.append(id)
        return TmuxSubmission(id: id, wire: Array(commandLine.utf8) + [0x0A])
    }

    /// Feed raw channel bytes: parse, fold structural events into ``state``,
    /// resolve completed commands FIFO, and advance ``lifecycle``. Returns what
    /// changed this call.
    public func feed(_ bytes: [UInt8]) -> TmuxControllerOutput {
        let beforeState = state
        let beforeLifecycle = lifecycle
        var resolved: [ResolvedCommand] = []
        var paneOutput: [PaneOutputChunk] = []

        for event in parser.feed(bytes) {
            if case .commandResult(_, let outcome) = event {
                // FIFO match. An empty queue means the spontaneous initial attach
                // block (or a stray) — drop it, don't fabricate a resolution.
                if !pending.isEmpty {
                    resolved.append(ResolvedCommand(id: pending.removeFirst(), outcome: outcome))
                }
                continue
            }
            if case .output(let pane, let data) = event {
                paneOutput.append(PaneOutputChunk(pane: pane, data: data))
                continue   // output is application data, not a structural state event
            }
            advanceLifecycle(for: event)
            state.apply(event)
        }

        let justAttached = beforeLifecycle == .attaching && lifecycle == .attached
        let prime = justAttached
            ? ["refresh-client -C 80x24",
               TmuxCommand.listWindowsForLayout(),
               TmuxCommand.queryAlternateOn()]
            : []

        return TmuxControllerOutput(
            lifecycleChanged: lifecycle != beforeLifecycle,
            stateChanged: state != beforeState,
            resolved: resolved,
            paneOutput: paneOutput,
            attachedPrimeCommands: prime
        )
    }

    /// Apply externally-synthesized events (e.g. from a `list-windows` reply parsed
    /// by ``windowListingEvents(_:sessionID:)``) through the same `state.apply(_:)`
    /// path `feed` uses. Returns true if any changed structural state. Used by the
    /// runtime to populate windows when tmux emitted none on attach.
    public func applyEvents(_ events: [ControlModeEvent]) -> Bool {
        let before = state
        for event in events { state.apply(event) }
        return state != before
    }

    /// Advance the lifecycle for a non-result event: first `%session-changed`
    /// confirms attach; `%exit` is terminal.
    private func advanceLifecycle(for event: ControlModeEvent) {
        switch event {
        case .sessionChanged:
            if lifecycle == .attaching { lifecycle = .attached }
        case .exit(let reason):
            if case .exited = lifecycle { return }
            lifecycle = .exited(reason: reason)
        default:
            break
        }
    }
}
