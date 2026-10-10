// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import SwiftTerm
import UIKit
import SemicolynKit
import SemicolynSSHCoreFFI

/// Byte floor that separates mosh's ~13B restore-time terminal-open sequence from the
/// real full-screen repaint our forced Ctrl-^ Ctrl-L provokes, for the state-resume
/// liveness check (see `ConnectionViewModel.onOutput`). On restore mosh emits only the
/// terminal-open sequence (a couple dozen bytes) up front; a live server's forced
/// repaint is larger even for a bare shell prompt (cursor positioning + the prompt
/// string + SGR easily exceed this). 64 bytes is comfortably above the open sequence
/// and below any real repaint. Fails SAFE: a dead/unreachable server produces no
/// repaint, so cumulative output never crosses the floor and the watchdog does a
/// harmless fresh reconnect rather than a false "alive".
private let moshStateResumeLivenessFloorBytes = 64

/// Crash-banner presentation state (degraded-mode spec). One case today.
enum CrashBannerState: Equatable { case tmuxEnded }

/// A modal the session presents in response to a hardware-keyboard Cmd-shortcut
/// (Phase 4e). The VM publishes the intent; `SessionView` shows the sheet.
enum SessionSheet: Identifiable {
    case settings, launcher, tips, hostPicker
    /// Confirm-and-connect prompt for a tapped ssh:// link (Phase-3c seam).
    case quickConnect(SSHConnectTarget)
    var id: String {
        switch self {
        case .settings: return "settings"
        case .launcher: return "launcher"
        case .tips: return "tips"
        case .hostPicker: return "hostPicker"
        case let .quickConnect(t): return "quickConnect:\(t.user ?? "")@\(t.host):\(t.port ?? 22)"
        }
    }
}

/// Drives the one MVP flow: connect → password auth → probe tmux → launch plain
/// tmux or degrade to a raw-PTY shell.
/// Retains the live `Connection`, `ShellSession`, and optionally `PlainTmuxController`.
@MainActor
final class ConnectionViewModel: ObservableObject, PredictorPurgeable {
    enum State: Equatable {
        case idle
        case connecting
        case shell
        case failed(String)
    }

    @Published var state: State = .idle {
        didSet {
            // Bump the connection epoch on every ENTRY into `.shell` (from any other
            // state), so SessionView's `.id(connectionEpoch)` forces a FRESH mount of
            // the terminal view per connection. Without this, a reattach (disconnect ->
            // .idle -> reattach -> .shell) reuses the existing TerminalScreen: SwiftUI
            // calls updateUIView, not makeUIView, so `output.onBytes` (set ONLY in
            // makeUIView) is never re-attached after teardown nil'd it, and Mosh frames
            // pile unrendered in PendingOutputBuffer = blank/frozen reconnect (device bug
            // 2026-09-06/07). A fresh mount re-attaches the sink and flushes the buffer.
            if state == .shell, oldValue != .shell {
                connectionEpoch &+= 1
                DebugLog.shared.log(.lifecycle, "connectionEpoch -> \(connectionEpoch) (fresh terminal mount)")
            }
            // A failed/ended connection must never stay hidden behind the connecting
            // overlay. (`.connecting` is NOT an end: Mosh's onFirstFrame can fire, and
            // raise the overlay, synchronously inside `sess.start()` before `.shell`.)
            switch state {
            case .idle, .failed: evaluateConnectReveal(sessionEnded: true)
            case .connecting, .shell: break
            }
        }
    }
    /// Increments on every entry into `.shell` (see `state.didSet`). Drives
    /// SessionView's `.id()` so each connection/reattach remounts the terminal view,
    /// guaranteeing `makeUIView` re-attaches the render sink. Published so the `.id()`
    /// re-evaluates.
    @Published private(set) var connectionEpoch: Int = 0
    @Published var pendingPrompt: HostKeyPrompt?
    /// Set by a Cmd-shortcut to ask `SessionView` to present a modal (Phase 4e).
    @Published var presentedSheet: SessionSheet?
    /// Non-nil when we fell back from tmux to a raw shell; drives the amber banner
    /// explaining why tmux wasn't used.
    @Published var degraded: DegradeReason?
    /// Non-nil when a cold Mosh/ET resume reattach failed: carries the host label for
    /// the failure banner ("Couldn't resume <host>."). The persisted record is already
    /// cleared; `resumeInMemory` holds the reattach info so the banner's Retry works.
    /// Set by `resumeColdReattach` on failure; cleared when the user leaves the banner.
    @Published var resumeFailure: String?
    /// Non-nil when a raw-SSH resume record wants confirmation on launch: carries the
    /// host label for the inline "Reconnect to <host>?" prompt. Cleared on either choice.
    @Published var resumeRawPrompt: String?
    /// Held-in-memory reattach info for the failure banner's Retry (the persisted copy
    /// is cleared on failure per the spec; leaving the banner drops this). Retry rebuilds
    /// the transport from this record + its (in-memory) secret.
    private var resumeInMemory: (host: Host, record: ResumableSession, secret: Data)?
    /// The raw-SSH record awaiting the inline "Reconnect to <host>?" prompt, so Decline
    /// clears the correct record (a fresh VM's `sessionID` is unrelated to it).
    private var resumeRawRecord: ResumableSession?
    /// Last OSC 0/2 title received from the remote (sanitized). Phase-4 Esc-pill
    /// Live row reads this to display the current window title.
    @Published var terminalTitle: String?
    /// Whether OSC 52 clipboard writes are permitted for the active session.
    /// Resolved from `resolveOsc52Allow` at connect time; read by the terminal views.
    private(set) var osc52Allowed: Bool = true
    /// Predictor-strip suggestion state, split into its own observable slice so a
    /// suggestion recompute invalidates only the predictor-strip views (Plan B §B1).
    let predictorVM = PredictorViewModel()
    /// Nil when the predictor is disabled for this session (incognito).
    private var predictor: PredictorActor?
    private var tracker = InputTokenTracker()
    /// Last-observed values of the tracker's monotonic secret-exclusion drop tallies,
    /// so `observePredictorInput` can log the PER-CHUNK delta (privacy-safe: counts of
    /// tokens the L3-paste / L4b-secret gates dropped, never the token text). Reset to 0
    /// whenever the tracker is reset (context/host switch), mirroring the tracker's own
    /// counter reset. Enables the `.predictor` `drop-gate` line the audit found missing.
    private var lastDropInPaste = 0
    private var lastDropAsSecret = 0
    /// Trailing-debounce so a typing burst recomputes suggestions once, not per
    /// keystroke (Plan B).
    // 0.035 < the 40ms settle-hop delay so the folded `isDue` check clears the window
    // with margin (the refresh runs inside the 40ms echo-settle hop; a 40ms window would
    // land exactly on the threshold). Trailing-debounce intent unchanged: a newer
    // keystroke within ~35ms still defers the recompute.
    private var refreshCoalescer = SuggestionRefreshCoalescer(quietWindow: 0.035)
    /// Monotonic tag assigned (in keystroke order, on the main actor) to each
    /// suggestion refresh so the async `suggest`→`surface` boundary can be aligned in
    /// the device log: if a lower `seq` surfaces AFTER a higher one, an older prefix's
    /// results landed out of order (stale-chip hazard). Diagnostic-only.
    private var predictorRefreshSeq = 0
    private var learnedStore: LearnedStore?
    /// Write-time gate keeping typed secrets out of the learned vocabulary
    /// (`observePredictorInput`). See `PasswordEntryDetector`. Lazily wires the
    /// L1 echo oracle to the active pane's rendered grid on first access.
    private lazy var passwordDetector: PasswordEntryDetector = {
        var d = PasswordEntryDetector()
        d.setOracle(SwiftTermEchoOracle(resolveActiveView: { [weak self] in
            self?.activePaneView()
        }))
        return d
    }()
    /// Tokens committed on the current input line, buffered until the line commits
    /// so the whole line is learned or dropped as a unit per the detector verdict.
    private var pendingLineTokens: [CommittedToken] = []

    /// Fn-layer state for the active pane. Published so the keybar re-renders the
    /// Fn slot and the F-key layer.
    @Published private(set) var fnState = FnState()
    /// Set when the Mosh session crashed or ended mid-session (its exit path). The
    /// crash banner persists until the user acts (Reconnect).
    @Published var crashBanner: CrashBannerState? {
        didSet { if crashBanner != nil { evaluateConnectReveal(sessionEnded: true) } }
    }
    /// True while the "Connecting to <host>..." overlay covers the mounted terminal: from
    /// the plain-tmux launch (Mosh fresh connect: first frame of the direct launch, or the
    /// in-band launch; ET; Mosh fresh-relaunch
    /// reattach) until `connectRevealDecision` says tmux has painted (or the launch
    /// failed / timed out). The terminal stays mounted underneath so it keeps receiving
    /// output, sizing and first responder. Raised by `beginConnectOverlay()`, lowered
    /// only by `evaluateConnectReveal`.
    @Published private(set) var connectOverlay = false
    /// `systemUptime` when the overlay went up (in-band launch typed, or the direct
    /// launch's first frame).
    private var connectOverlayLaunchedAt: TimeInterval = 0
    /// True once the `SEMICOLYN_LAUNCH` sentinel has appeared in the launch output.
    private var connectOverlaySentinelSeen = false
    /// `systemUptime` of the latest output chunk that arrived AFTER the chunk carrying
    /// the sentinel (nil until one does; see `ConnectRevealInput.secondsSinceLastOutput`).
    private var connectOverlayLastOutputAt: TimeInterval?
    /// Terminal mouse reporting as last reported while the overlay is up
    /// (`noteTerminalMouseMode`). Reset to false at launch.
    private var connectOverlayMouseOn = false
    /// True once the reactive probe classified tmux as missing AFTER the current
    /// `beginConnectOverlay()` (set in `evaluatePlainTmuxProbe`, reset at begin). Read
    /// instead of `degraded`, which can still hold a stale `.tmuxNotFound` from an earlier
    /// launch and would otherwise reveal a later relaunch instantly.
    private var connectOverlayTmuxMissing = false
    /// Fires the reveal check at the `connectRevealTimeoutSeconds` deadline.
    private var connectOverlayTimeout: Task<Void, Never>?
    /// Re-checks once the quiet window after the latest post-sentinel output elapses, so
    /// `sentinelQuiet` fires without needing another output chunk.
    private var connectOverlayQuietCheck: Task<Void, Never>?
    /// Bumped when the app wants the active terminal to re-claim first responder
    /// (e.g. returning from the Settings sheet, which resigned it). The raw
    /// terminal observes this and calls `becomeFirstResponder()`.
    @Published private(set) var keyboardFocusRequestToken: Int = 0

    private var promptContinuation: CheckedContinuation<Bool, Never>?

    private var connection: Connection?
    /// Non-nil while a Mosh session is driving the terminal (mutually exclusive
    /// with `etSession`). Retained so teardown can shut the UDP loop down.
    private var moshSession: MoshSession?
    /// True once the current Mosh session has delivered its first output frame (the
    /// UDP handshake completed). Gates `onEnd`: a pre-first-frame exit falls back to
    /// SSH on the retained connection; a post-first-frame exit is a mid-session crash.
    private var moshFirstFrameSeen = false
    /// Non-nil while an ET (Eternal Terminal) session is driving the terminal.
    /// Retained so it outlives `attachET` and teardown can close it. TEMPORARY:
    /// `attachET` has no routing entry point yet (Transport picker is a later
    /// slice), so this is unused outside that dev-only call for now.
    private var etSession: ETSession?
    /// First-frame watchdog: fires an SSH fallback if the Mosh loop signals no life
    /// (no onFirstFrame, no onEnd) within the window. Cancelled by either callback.
    private var moshWatchdog: Task<Void, Never>?
    /// Cold-reattach liveness watchdog. A direct mosh RE-HOME to the stored port only
    /// works if that mosh-server is still alive; if it died (mosh-server has no default
    /// no-client timeout so it also cannot be relied upon, and an app-kill sends no UDP
    /// disconnect), the re-homed client paints only its last-known LOCAL frame and then
    /// hangs, with NO onEnd (UDP has no teardown) -> a permanently frozen reconnect
    /// (device 2026-09-07, Blink-confirmed model). This watchdog proves liveness by
    /// requiring REAL server output AFTER our in-band relaunch; on timeout it tears the
    /// dead session down and falls back to a fresh SSH bootstrap connect (which spawns a
    /// new mosh-server and provably works). Cancelled once live output is seen; cleared
    /// in teardown().
    private var moshReattachWatchdog: Task<Void, Never>?
    /// True once server output has arrived AFTER the reattach's in-band relaunch was
    /// sent (proving the re-homed mosh-server is alive, distinct from the initial local
    /// restored-frame paint that arrives at onFirstFrame). The liveness watchdog reads
    /// this; it is deliberately SEPARATE from `plainTmuxProbeResolved`, which the plain
    /// tmux probe's own 2s "assume started" timer flips even with no server response.
    private var moshReattachSawServerOutput = false
    /// True once a terminal Mosh handler (the watchdog fallback OR `onEnd`) has
    /// resolved this session. Guards against the watchdog and an already-enqueued
    /// `onEnd` both running their branch (main-actor-serialized, so a flag suffices):
    /// e.g. the watchdog attaches SSH, then a queued `onEnd` would otherwise clobber
    /// it with a spurious crash banner. Reset in `teardown()` with the rest of Mosh state.
    private var moshResolved = false
    /// True from app-background suspend (`suspendMoshForBackground`) until the warm
    /// foreground re-home starts (`resumeMoshOnForegroundIfNeeded`). The suspend tears
    /// the live mosh session down and flips `state` to `.idle` so the foreground guard
    /// (`guard state == .idle`) passes, BUT the SessionView cover must NOT dismiss on
    /// that `.idle` (it would drop us to the host list and the in-place re-home would
    /// never run). SessionView's `.onChange(state)` reads this and suppresses `dismiss()`
    /// while a suspend is pending, exactly as `resumeFailure != nil` does for the banner.
    var moshSuspendedForResume = false
    /// State-resume liveness plumbing. On a STATE-resume (blob replay) we do NOT re-send
    /// the plain-tmux launch (attach-or-create), so the SEMICOLYN_LAUNCH sentinel the fresh-relaunch watchdog keys
    /// off is never printed. Instead reattachMosh forces a full repaint (Ctrl-^ Ctrl-L),
    /// and the server's repaint output crossing `moshStateResumeLivenessFloorBytes` proves
    /// the re-home is live (`moshStateResumeSawServerOutput`) and cancels the watchdog. If
    /// no repaint arrives (dead/unreachable server), the watchdog does a fresh bootstrap
    /// connect instead of a frozen restored screen (Important-3 safety net). Reset in
    /// `teardown()` and on each `armMoshStateResumeWatchdog`.
    private var moshStateResumeSawServerOutput = false
    /// Cumulative onOutput bytes since the state-resume onFirstFrame, compared against the
    /// liveness floor (see the onOutput closure). Reset per reattach.
    private var moshStateResumeBytesSinceFirstFrame = 0
    /// ET connect watchdog: fails the connect if the session shows no life (no
    /// onFirstFrame, no onEnd) within the window. Cancelled by either callback.
    private var etWatchdog: Task<Void, Never>?
    /// True once a terminal ET handler (watchdog timeout OR onFirstFrame OR onEnd)
    /// has resolved this session. Guards against double-resolution.
    private var etResolved = false
    /// True once ET's `onFirstFrame` fired for the current session. Drives
    /// `etExitDecision`: a session that reached first-frame and then ended is a
    /// graceful dismiss; one that never did is a pre-connect handshake failure.
    /// Reset in `teardown()`.
    private var etFirstFrameSeen = false
    /// True from the moment the user initiates a disconnect ("x" button -> `disconnect()`)
    /// until the next connect attempt. ET's `onEnd` is asynchronous and fires AFTER
    /// `teardown()` has closed the session; without this guard it reads the already-reset
    /// `etFirstFrameSeen == false` and misroutes a user disconnect to
    /// `.failed("could not connect: closed")`. `onEnd` checks this FIRST and, when set,
    /// cleans up silently (no `.failed`, no banner). Reset at connect-start (NOT in
    /// `teardown()`, which runs before the async `onEnd` and would clear it too early).
    private var etUserDisconnecting = false
    /// Set when we bootstrapped Mosh but fell back to SSH before handoff. Consumed
    /// by `SessionView` to show a one-line banner (parallels `degraded`/`crashBanner`).
    @Published var moshFallback: String?
    /// Last saved-host connect args, retained so `⇧⌘R` can reconnect (Phase 4e).
    private var lastSavedHost: Host?
    /// Stable per-connection id. Minted at each `connect(...)` start and used as the
    /// key for the connection-resume record (capture at the connected edge, clear at
    /// every observable end). One live connection at a time, so one id at a time.
    private var sessionID = UUID()
    /// The resolved tmux session name for the current connection, computed once at
    /// connect time and reused by attach + the reattach/start-new banner actions.
    private var tmuxSessionNameForConnection = builtInTmuxSessionName
    private var lastPassword: String?
    private(set) var session: ShellSession?
    /// Serializes raw-PTY keystroke writes (FIFO under channel back-pressure).
    /// Used by the SSH raw and plain-tmux paths (Mosh/ET write to their own session).
    private var rawWriter: SerialByteWriter?
    /// Non-nil while the gesture-driven plain tmux route is active, driven
    /// per-host/default by `resolveUseTmux`. The byte stream rides the same raw
    /// single-terminal path as `rawWriter` (`output.onBytes`/`terminal.feed`);
    /// this only holds the gesture-command controller.
    private(set) var plainTmux: PlainTmuxController?
    /// True once the plain-tmux in-band launch (attach-or-create) has
    /// been sent for the current Mosh session (idempotency guard: `onFirstFrame`
    /// is documented once-only per `MoshSession`, but this flag makes the send
    /// itself robust to any future re-fire). Reset in `teardown()`.
    private var moshPlainTmuxLaunchSent = false
    /// True when the current FRESH Mosh session's mosh-server runs the plain-tmux launch
    /// as its session command (`plainTmuxDirectLaunchCommand` after `--` in the
    /// bootstrap), so `onFirstFrame` must NOT type the in-band launch. Set at bootstrap,
    /// reset in `teardown()`. Reattach never sets it.
    private var moshDirectLaunch = false
    /// True once the direct launch's `SEMICOLYN_NOTMUX` marker triggered the one-time
    /// in-band launch fallback (tmux not on the non-interactive PATH; the user is now at
    /// their login shell, whose PATH may have it). At most once per connection. Reset at
    /// bootstrap and in `teardown()`.
    private var moshDirectLaunchFallbackSent = false
    /// Direct-launch output accumulated (bounded at 16384 bytes) to find the marker
    /// across chunk boundaries. Separate from `plainTmuxProbeBuffer`, which stops
    /// accumulating once the sentinel is seen (the marker follows the sentinel). Reset at
    /// bootstrap, on the fallback, and in `teardown()`.
    private var moshDirectLaunchOutput = ""
    /// Same idempotency guard as `moshPlainTmuxLaunchSent`, for the ET plain-tmux
    /// route (a distinct flag so neither transport's reset touches the other's
    /// state). Reset in `teardown()`.
    private var etPlainTmuxLaunchSent = false
    /// True once a plain-tmux in-band launch has actually been SENT for the
    /// current Mosh/ET session (mirrors `moshPlainTmuxLaunchSent`/
    /// `etPlainTmuxLaunchSent`, but transport-agnostic: gates whether `onOutput`
    /// accumulates into `plainTmuxProbeBuffer` at all, so a raw non-tmux session
    /// never pays the classify cost). Reset in `teardown()`.
    private var plainTmuxProbeArmed = false
    /// Accumulates decoded output bytes seen during the reactive tmux-launch
    /// probe window (Mosh/ET only; SSH's `tmuxLaunchDecision` probes BEFORE
    /// launch and never needs this). Fed to `classifyTmuxLaunch` on every
    /// `onOutput` call until resolved or the watchdog expires. Reset in
    /// `teardown()`.
    private var plainTmuxProbeBuffer = ""
    /// True once the reactive probe has reached a verdict (`.tmuxMissing`/
    /// `.tmuxStarted`) or the watchdog window expired (`.inconclusive` ->
    /// assume started). Once-only: further `onOutput` bytes stop accumulating
    /// and `evaluatePlainTmuxProbe` becomes a no-op. Reset in `teardown()`.
    private var plainTmuxProbeResolved = false
    /// Whether Mosh/ET `onOutput` should keep accumulating launch output into
    /// `plainTmuxProbeBuffer`: while the tmux-missing probe is unresolved, and after that
    /// until the launch sentinel has been seen (the Mosh cold-reattach liveness signal can
    /// trail the probe's 2s "assume started" timer). Bounded at 16384 bytes so a shell that
    /// never prints the sentinel cannot grow the buffer without limit, while leaving room
    /// for a large restored-frame paint that lands BEFORE the sentinel (a smaller cap could
    /// stop accumulating first and cut the reattach liveness check off early). A raw
    /// non-tmux session that never armed the probe short-circuits on `plainTmuxProbeArmed`.
    private var shouldAccumulatePlainTmuxProbe: Bool {
        guard plainTmuxProbeArmed else { return false }
        if !plainTmuxProbeResolved { return true }
        return !containsPlainTmuxLaunchSentinel(plainTmuxProbeBuffer)
            && plainTmuxProbeBuffer.utf8.count < 16384
    }
    /// Bounded watch (~2s) started when the in-band plain-tmux launch is sent;
    /// classifies the accumulated `plainTmuxProbeBuffer` on expiry if nothing
    /// resolved it sooner. Cancelled on resolution or `teardown()`.
    private var plainTmuxProbeWatchdog: Task<Void, Never>?
    /// Shared output sink; the terminal view wires `onBytes` to render into itself.
    let output = TerminalShellOutput()

    /// Routes keybar gesture events to terminal bytes. Modifier-state changes
    /// publish through the VM so the keybar's armed/locked slot visuals re-render.
    private(set) lazy var keybar: KeybarInputRouter = {
        let r = KeybarInputRouter(
            applicationCursorKeys: { [weak self] in self?.activePaneApplicationCursor() ?? false },
            send: { [weak self] bytes in self?.sendTerminalInput(bytes) })
        r.onModifierChange = { [weak self] in self?.objectWillChange.send() }
        return r
    }()

    // MARK: - Host-key prompt

    /// Show a host-key modal and suspend until the user decides. One prompt is
    /// in flight per handshake; if a stale continuation somehow remains, resolve
    /// it as rejected (the safe direction) rather than leaking its task.
    func present(_ prompt: HostKeyPrompt) async -> Bool {
        DebugLog.shared.log(.connect, "hostkey: prompt shown (\(String(describing: prompt).prefix(60)))")
        return await withCheckedContinuation { cont in
            promptContinuation?.resume(returning: false)
            promptContinuation = cont
            pendingPrompt = prompt
        }
    }

    /// Called by the view when the user taps a modal button.
    func resolvePrompt(_ trusted: Bool) {
        DebugLog.shared.log(.connect, "hostkey: prompt resolved trusted=\(trusted)")
        pendingPrompt = nil
        promptContinuation?.resume(returning: trusted)
        promptContinuation = nil
    }

    // MARK: - Input routing

    func fnTap() { fnState.tap() }
    /// Send an F-key and clear a one-shot Fn arm.
    func fnTapFKey(_ n: Int) {
        keybar.tapFKey(n)
        fnState.fireFKey()
        DebugLog.shared.log(.input, "input:fnKey n=\(n)")
    }

    /// Characters typed on the terminal keyboard (SwiftTerm delegate). Routed
    /// through the keybar router so an armed Ctrl/Alt/Shift applies to real keyboard
    /// keys (e.g. armed Ctrl + 'a' → 0x01), then flows on to `sendTerminalInput`.
    /// Unmodified input passes straight through unchanged.
    func terminalKeyboardInput(_ bytes: [UInt8]) {
        keybar.keyboardInput(bytes)
        DebugLog.shared.log(.input, "input:keyboard bytes=\(bytes.count)")
    }

    /// Route terminal keystrokes to the active transport: the ET stream, the Mosh
    /// session, else the raw-PTY channel.
    func sendTerminalInput(_ bytes: [UInt8]) {
        // ── SACRED PATH ─────────────────────────────────────────────────────────
        // The transport write is the FIRST thing that happens, nothing (not even a
        // string interpolation) runs ahead of it. Do NOT add work above this block.
        let signpost = PerfSignposts.input.beginInterval("send")
        if let etSession {
            etSession.send(Data(bytes))
        } else if let moshSession {
            moshSession.writeInput(Data(bytes))
        } else {
            rawWriter?.enqueue(bytes)
        }
        PerfSignposts.input.endInterval("send", signpost)
        // ── after the write: diagnostics (gated no-op) + forked observation ───────
        // `log` is an @autoclosure that is a no-op unless diagnostics is enabled, so
        // this string is not even built in normal use. Structure only (byte count),
        // never content: this line sees every keystroke including secrets.
        // Mirror the dispatch order above: ET, then Mosh, then raw PTY.
        let transport = etSession != nil ? "ET" : (moshSession != nil ? "MOSH" : "RAW")
        DebugLog.shared.log(.input, decisionLine(
            "input:dispatch",
            inputs: [("bytes", "\(bytes.count)")],
            outputs: [("transport", transport)],
            reason: nil))
        observePredictorInput(bytes)
    }

    /// DECCKM (application-cursor-keys) state of the active pane's terminal.
    /// Only the removed -CC path registered pane views; plain tmux and raw shell
    /// have none, so this is false (unchanged behavior). Pointing it at the
    /// mounted terminal is a separate follow-up.
    private func activePaneApplicationCursor() -> Bool {
        false
    }

    /// The `TerminalView` the user is currently typing into (L1 echo oracle and the
    /// predictor's alt-screen check).
    /// Only the removed -CC path registered pane views; plain tmux and raw shell have
    /// none, so this is nil (unchanged behavior). Pointing it at the mounted terminal
    /// is a separate follow-up.
    private func activePaneView() -> TerminalView? {
        nil
    }

    // MARK: - tmux

    /// True while the plain tmux route is active (drives horizontal drag = window
    /// switch vs. scroll fall-through). The plain-tmux route (`plainTmux`) tracks
    /// no window count (blind switch, see `PlainTmuxController` doc), so it always
    /// reports true while active: the drag-switch gesture must stay live even
    /// though we cannot confirm >1 window ahead of a swipe.
    var isMultiWindowTmux: Bool { plainTmux != nil }

    /// Whether the in-progress input line looks like a password/secret entry, per
    /// `passwordDetector`'s verdict (used ONLY to gate diagnostic key-content logging,
    /// see `TerminalScreen.Coordinator.send`; has no effect on predictor learning, which
    /// reads the detector directly).
    func currentLineIsPassword() -> Bool { !passwordDetector.shouldLearnCommittedLine() }

    // MARK: - Hardware-keyboard commands (Phase 4e)

    /// Dispatches a resolved hardware-keyboard command to its action. Window/pane
    /// commands are currently no-ops; presentation commands publish a
    /// `presentedSheet` intent for `SessionView`.
    func perform(_ command: KeyboardCommand) {
        DebugLog.shared.log(.input, "input:command \(command)")
        switch command {
        case .newWindow, .closeWindow, .switchWindow, .prevWindow, .nextWindow,
             .prevPane, .nextPane, .splitVertical, .splitHorizontal:
            break   // window/pane commands: removed with -CC (plain-tmux rewire is a follow-up)
        case .clearScreen:         sendTerminalInput([0x0c])              // Ctrl-L
        case .paste:               pasteFromClipboard()
        case .reconnect:           reconnect()
        case .newConnection:       presentedSheet = .hostPicker
        case .openLauncher:        presentedSheet = .launcher
        case .settings:            presentedSheet = .settings
        case .tips:                presentedSheet = .tips
        case .copy:                break   // SwiftTerm handles ⌘C natively on the hardware path
        }
    }

    /// Paste the system clipboard's text into the terminal (`⌘V`, hardware path).
    private func pasteFromClipboard() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        sendTerminalInput(Array(text.utf8))
    }

    /// Re-run the last saved-host connect (`⇧⌘R`). No-op if nothing connected yet.
    func reconnect() {
        guard let host = lastSavedHost else {
            DebugLog.shared.log(.connect, "reconnect: ABORT no lastSavedHost")
            return
        }
        DebugLog.shared.log(.connect, "reconnect: triggered for \(host.hostName)")
        connect(savedHost: host, password: lastPassword ?? "")
    }

    /// Ask the active terminal to re-show the keyboard + keybar. Safe to call when
    /// already first responder (the container no-ops in that case).
    func requestKeyboardFocus() {
        keyboardFocusRequestToken &+= 1
        DebugLog.shared.log(.input, "key:requestKeyboardFocus token=\(keyboardFocusRequestToken)")
    }

    // MARK: - Teardown

    /// User-initiated disconnect (the connected-state Disconnect button). Tears the
    /// session down and flips `state` to `.idle` so the view can dismiss back to the
    /// host list. Flushes the predictor first (teardown already does), so learning
    /// survives an explicit disconnect just like a backgrounded one.
    func disconnect() {
        DebugLog.shared.log(.lifecycle, "disconnect: user-initiated teardown → .idle")
        etUserDisconnecting = true   // ET onEnd (async) must not misfire a .failed
        teardown()
        state = .idle
    }

    /// Reset all connection and pane state. Call at the start of each connect
    /// attempt so no stale handles or buffered bytes carry over to the new session.
    private func teardown() {
        // Every observable end clears the resume record for the current session
        // (clean disconnect routes through here; so do the ET .dismiss/.handshakeFailed
        // and crash-recovery paths). Idempotent + secret-clearing. Runs before a fresh
        // connect mints a new `sessionID`, so a new session is never clobbered.
        clearResume()
        moshWatchdog?.cancel(); moshWatchdog = nil
        moshReattachWatchdog?.cancel(); moshReattachWatchdog = nil
        moshReattachSawServerOutput = false
        moshResolved = false
        moshStateResumeSawServerOutput = false
        moshStateResumeBytesSinceFirstFrame = 0
        moshSuspendedForResume = false
        moshSession?.stop()
        moshSession = nil
        moshFirstFrameSeen = false
        moshFallback = nil
        etWatchdog?.cancel(); etWatchdog = nil
        etResolved = false
        etFirstFrameSeen = false
        etSession?.close()
        etSession = nil
        plainTmux = nil
        plainTmuxSessionNamePendingInstall = nil
        moshPlainTmuxLaunchSent = false
        moshDirectLaunch = false
        moshDirectLaunchFallbackSent = false
        moshDirectLaunchOutput = ""
        etPlainTmuxLaunchSent = false
        plainTmuxProbeArmed = false
        plainTmuxProbeBuffer = ""
        plainTmuxProbeResolved = false
        plainTmuxProbeWatchdog?.cancel(); plainTmuxProbeWatchdog = nil
        // Drop the connecting overlay (logs reason=sessionEnded once if it was up) and
        // cancel its timers. No-op when it is already down.
        evaluateConnectReveal(sessionEnded: true)
        fnState.reset()
        rawWriter?.finish()
        rawWriter = nil
        session = nil
        connection = nil
        crashBanner = nil
        flushPredictor()
        // Drop the render + harvest closures so late bytes from the old session
        // can't feed a torn-down terminal view or a cleared predictor. Both are
        // re-installed when the next shell opens. `onExit` goes too: a user
        // disconnect closes the PTY, whose async exit callback would otherwise
        // fire `output.onExit → .failed("Session closed")` right after `state`
        // flips to `.idle`, flashing a bogus failure banner on the way out. It
        // is re-installed at every connect entry point, so clearing it here is
        // safe. (Mirrors the ET path's `etUserDisconnecting` guard for the raw/
        // SSH transport, which routes exits through this closure instead.)
        output.onBytes = nil
        output.onHarvestBytes = nil
        output.onExit = nil
        predictor = nil
        // Deregister from the active-purge slot (the VM may be reused on reconnect
        // without deallocating, so the weak ref alone isn't enough).
        if AppStores.shared.activePredictorSession === self {
            AppStores.shared.activePredictorSession = nil
        }
        tracker.reset()
        lastDropInPaste = 0               // mirror the tracker's monotonic drop-tally reset
        lastDropAsSecret = 0
        passwordDetector.reset()          // clear echo/prompt state across sessions
        pendingLineTokens.removeAll()     // drop any un-flushed line tokens
        predictorVM.setSuggestions([])
    }

    // MARK: - Connection resume

    /// Whether the active session is on the gesture-driven plain-tmux route, i.e.
    /// whether a resume record should carry `tmuxSessionNameForConnection` at all.
    /// A plain-tmux SSH session is captured
    /// as a bare raw-SSH `.promptRaw` record either way (see `resumeDecision`,
    /// which branches purely on `record.transport`, never on `tmuxSessionName`),
    /// but `tmuxSessionNameForConnection` is exactly the name `attachPlainTmux`
    /// launched with (set right before it runs), and
    /// `resolveTmuxSessionName` is a DETERMINISTIC function of `host`/`defaults`
    /// (no randomness, see `Resolution.swift`), so a later `resumeRawReconnect` →
    /// `connect(savedHost:)` re-derives the SAME name and re-enters the SAME gate
    /// (`attachSSHShell`) that launched it, the plain-tmux launch (attach-or-create) then reattaches
    /// the still-running session either way. This flag exists purely so the
    /// captured record's `tmuxSessionName` metadata is accurate for anything that
    /// inspects it (diagnostics, the `resume:capture` log line's `tmux=` field), not
    /// because the resume-READ path branches on it.
    private var isTmuxSession: Bool { plainTmux != nil }

    /// Persist a resumable record at a transport's connected edge. Raw SSH passes
    /// `secret: nil` (it reconnects fresh after a prompt); Mosh/ET pass their reattach
    /// credential. The tmux session name rides for a plain-tmux session
    /// (`isTmuxSession`). SECURITY: the secret goes straight to
    /// the store; it is never logged here or in the coordinator.
    private func captureResume(host: Host, transport: Transport,
                               endpoint: (host: String, port: Int), secret: Data?) {
        let tmuxName = isTmuxSession ? tmuxSessionNameForConnection : nil
        AppStores.shared.resume.captureConnected(
            sessionID: sessionID, host: host, transport: transport,
            endpoint: endpoint, secret: secret, tmuxSessionName: tmuxName)
    }

    /// Clear the resumable record for the current session. Called at every observable
    /// end (clean disconnect, teardown, mid-flight error). Idempotent.
    private func clearResume() {
        AppStores.shared.resume.clear(sessionID: sessionID)
    }

    // MARK: - Resume executor (launch)

    /// Execute a `ResumeAction` on launch. `.reforeground` is a warm no-op here (the
    /// live VM already holds the session); the App only reaches this VM cold (a fresh
    /// VM), so the meaningful cases are `.coldReattach` (Mosh/ET) and `.promptRaw`.
    /// `.none` is a normal launch.
    /// Execute a launch-resume action. Returns `false` when the caller should instead
    /// run its NORMAL fresh-connect path (with the caller's credential resolution): this
    /// is how ET cold-resume works, since ET cannot cold-reattach with a stored
    /// credential and must re-bootstrap over a fresh SSH connect (see `resumeColdReattach`).
    /// Returns `true` when the action was fully handled here (mosh reattach, raw prompt,
    /// reforeground, none).
    @discardableResult
    func executeResume(_ action: ResumeAction, host: Host) -> Bool {
        switch action {
        case .reforeground:
            // Warm reforeground is handled by the surviving VM; a fresh VM never gets
            // this. Log + no-op so an unexpected warm-on-cold is visible, not silent.
            DebugLog.shared.log(.connect, "resume:execute reforeground (no-op on fresh VM)")
            return true
        case .coldReattach(let record):
            // ET cold-resume is NOT a direct reattach: it re-bootstraps via a fresh
            // connect using the caller's credential resolution (key / stored-password /
            // prompt). Signal the caller to run its normal connect path.
            if record.transport == .et {
                // ET re-bootstraps via a fresh connect (below), which mints a NEW
                // sessionID and captures its own record. The record we resumed FROM is
                // now consumed: clear it so it can't re-trigger a resume on the next
                // launch. Without this, the stale record survives every disconnect
                // (which only clears the fresh session's id) and the app resumes on
                // every launch, even after an intentional disconnect. Mirrors the Mosh
                // path, where `resumeColdReattach` adopts `record.sessionID` so its own
                // teardown clears the same record; ET can't adopt (it re-bootstraps),
                // so it clears the resumed record explicitly here instead.
                DebugLog.shared.log(.connect, "resume:execute coldReattach et → clear resumed record, normal fresh connect (re-bootstrap + tmux -A)")
                AppStores.shared.resume.clear(sessionID: record.sessionID)
                return false
            }
            resumeColdReattach(host: host, record: record)
            return true
        case .promptRaw(let record):
            DebugLog.shared.log(.connect, "resume:execute promptRaw host=\(host.label)")
            resumeRawRecord = record
            resumeRawPrompt = host.label
            return true
        case .none:
            DebugLog.shared.log(.connect, "resume:execute none → normal launch")
            return false
        }
    }

    /// Cold Mosh/ET reattach: read the stored secret, rebuild the transport DIRECTLY
    /// to `record.host:record.port` (no SSH bootstrap: the mosh-server/etserver session
    /// persists server-side and is reachable with the stored key). On any failure clear
    /// the persisted record but KEEP an in-memory copy so the banner's Retry works.
    /// Cold MOSH reattach: read the stored MOSH_KEY, rebuild the transport DIRECTLY to
    /// `record.host:record.port` (no SSH bootstrap: the mosh-server session persists
    /// server-side and is reachable with the stored key). On any failure clear the
    /// persisted record but KEEP an in-memory copy so the banner's Retry works.
    ///
    /// ET is NOT handled here: it cannot cold-reattach with a stored credential (etserver
    /// roaming is for a LIVE process; a cold reattach does the INITIAL handshake the
    /// server won't honor, device-confirmed build 149 "handshake timeout"). ET cold-resume
    /// re-bootstraps via a fresh connect, routed by `executeResume` returning false.
    private func resumeColdReattach(host: Host, record: ResumableSession) {
        guard let secret = AppStores.shared.resume.secret(sessionID: record.sessionID) else {
            DebugLog.shared.log(.connect, "resume:coldReattach ABORT no secret → banner")
            failResume(host: host, record: record, secret: Data(), reason: "no stored secret")
            return
        }
        // Adopt this record's id so the connected-edge capture REFRESHES the same record
        // (and a later teardown clears the right one).
        sessionID = record.sessionID
        state = .connecting
        DebugLog.shared.log(.connect,
            "resume:coldReattach transport=\(record.transport.rawValue) endpoint=\(record.host):\(record.port)")
        switch record.transport {
        case .mosh: reattachMosh(host: host, record: record, key: secret)
        case .et:
            // Unreachable: ET is routed to a fresh connect by `executeResume` (returns false).
            DebugLog.shared.log(.connect, "resume:coldReattach et (unexpected) → banner")
            failResume(host: host, record: record, secret: secret, reason: "et unexpected")
        case .ssh:
            // Unreachable: raw SSH never yields .coldReattach (resumeDecision → .promptRaw).
            DebugLog.shared.log(.connect, "resume:coldReattach ssh (unexpected) → prompt")
            resumeRawPrompt = host.label
        }
    }

    /// On warm foreground (app kept in memory), if we suspended a mosh session on
    /// background (a state blob was persisted) and no live shell is up, re-home from
    /// the blob via the same cold-reattach path. Closes the warm-reopen gap (the
    /// cold-launch resume sweep runs only in HostListView.onAppear). isWarm:false is
    /// intentional: we want .coldReattach (blob-aware reattachMosh), not .reforeground
    /// (no handler; suspend already tore the local session down).
    /// Returns true if it kicked off an in-place re-home (state driven back to
    /// `.shell`); false if there was nothing to resume. SessionView uses the return to
    /// decide whether to dismiss a suspended-but-not-resumed cover.
    @discardableResult
    func resumeMoshOnForegroundIfNeeded() -> Bool {
        // Clear the suspend guard unconditionally on foreground: from here on the
        // SessionView cover may dismiss on `.idle` again (a stale flag would wrongly
        // pin a genuinely-finished session's cover open). `resumeColdReattach` below
        // drives `state` back to `.shell` on a successful re-home before any dismiss
        // can observe the cleared flag against `.idle`.
        let wasSuspended = moshSuspendedForResume
        moshSuspendedForResume = false
        guard state == .idle else { return false }
        let action = AppStores.shared.resume.resumeOnLaunch(isWarm: false)
        guard case let .coldReattach(record) = action else {
            DebugLog.shared.log(.connect, "resume:foreground no coldReattach action=\(String(describing: action)) wasSuspended=\(wasSuspended)")
            return false
        }
        guard let host = (try? AppStores.shared.hosts.host(id: record.hostID)) ?? nil else { return false }
        DebugLog.shared.log(.connect, "resume:foreground re-home host=\(host.label)")
        resumeColdReattach(host: host, record: record)
        return true
    }

    /// Rebuild a Mosh session directly from a stored record + MOSH_KEY. mosh-client
    /// needs a NUMERIC IP (AI_NUMERICHOST), so resolve the stored host again.
    private func reattachMosh(host: Host, record: ResumableSession, key: Data) {
        let keyStr = String(decoding: key, as: UTF8.self)
        guard let ip = MoshHostResolver.numericAddress(for: record.host) else {
            DebugLog.shared.log(.connect, "resume:reattachMosh could not resolve \(record.host) → banner")
            failResume(host: host, record: record, secret: key, reason: "couldn't resolve host")
            return
        }
        let blob = (try? AppStores.shared.moshState.get(sessionID: record.sessionID)) ?? nil
        let isStateResume = (blob?.isEmpty == false)
        DebugLog.shared.log(.connect,
            "resume:reattachMosh mode=\(isStateResume ? "state-resume" : "fresh-relaunch") blob=\(blob?.count ?? 0)B")
        let sess = MoshSession(ip: ip, port: String(record.port), key: keyStr,
                               cols: 80, rows: 24, predictMode: "adaptive",
                               encodedState: isStateResume ? blob : nil)
        // Mosh callbacks are dispatched to the main queue (MoshSession.h). These mirror
        // the fresh-attach closures' isolation pattern (bare `self.` access), which the
        // App target already compiles: the Obj-C block property is inferred main-actor
        // here, so no `MainActor.assumeIsolated` wrapper is needed (that guard is for
        // nonisolated SwiftTerm/@objc callbacks, not these blocks).
        sess.onOutput = { [weak self] data in
            guard let self else { return }
            self.output.onOutput(data: data)
            // Connecting overlay: runs after the probe accumulation below (on every exit
            // path) so the sentinel check sees this chunk.
            defer { self.noteConnectOverlayOutput() }
            // STATE-resume liveness (chunk-count discriminator, NOT a time gate).
            // Wire evidence (2026-09-10 tcpdump): mosh renders the restored screen from
            // LOCAL blob state SYNCHRONOUSLY at onFirstFrame, delivered as the FIRST
            // onOutput chunk. Every SUBSEQUENT chunk is a forward diff driven by an
            // inbound server datagram (the re-homed server's replay lands in the first
            // ~0.4s, interleaved with the paint) so the 2nd chunk onward proves a live
            // re-home. The previous 0.6s "restore settled" wall-clock timer discarded
            // exactly this proof: the server's real diffs arrived BEFORE 0.6s, then mosh
            // went into its ~3s idle heartbeat, so the post-settle window landed in a
            // silent gap and the watchdog false-fired a needless fresh reconnect (the
            // ~4s reconnect lag; device-confirmed). Counting chunks is immune to mosh's
            // idle cadence. Checked BEFORE the plain-tmux-probe guard below (state-resume
            // never arms that probe). Distinct from the fresh-relaunch sentinel path.
            if isStateResume, !self.moshStateResumeSawServerOutput {
                // LIVENESS via the forced repaint. On restore mosh writes only a ~13B
                // terminal-open sequence up front (it never paints the restored screen; see
                // the Ctrl-^ Ctrl-L rationale in reattachMosh). We then send Ctrl-^ Ctrl-L,
                // which makes the server emit the FULL screen repaint. So on the state-resume
                // path there is NO large "restored paint" chunk to discount: the first
                // SUBSTANTIAL output is the forced repaint = proof the server answered. We
                // accumulate bytes and confirm once cumulative output crosses a small floor
                // that the ~13B open sequence alone cannot reach but any real repaint (even a
                // bare shell prompt's) does. Fails SAFE: a dead/unreachable server produces
                // no repaint -> floor never crossed -> the 4s watchdog does a fresh reconnect
                // (harmless), never a frozen screen.
                self.moshStateResumeBytesSinceFirstFrame += data.count
                if self.moshStateResumeBytesSinceFirstFrame > moshStateResumeLivenessFloorBytes {
                    self.moshStateResumeSawServerOutput = true
                    self.moshReattachWatchdog?.cancel(); self.moshReattachWatchdog = nil
                    DebugLog.shared.log(.connect, "resume:reattachMosh state-resume repaint output \(self.moshStateResumeBytesSinceFirstFrame)B > floor → alive, confirmed")
                }
            }
            // Feed the reactive tmux-missing probe on reattach too (the re-sent
            // plain-tmux launch (attach-or-create) in onFirstFrame arms it), mirroring the fresh path.
            // Keep accumulating per `shouldAccumulatePlainTmuxProbe`.
            guard self.shouldAccumulatePlainTmuxProbe else { return }
            self.plainTmuxProbeBuffer += String(decoding: data, as: UTF8.self)
            self.evaluatePlainTmuxProbe()
            // Liveness proof for the cold-reattach dead-server watchdog: the
            // SEMICOLYN_LAUNCH sentinel is printed ONLY when the server actually EXECUTES
            // our in-band relaunch (the plain-tmux launch script's sentinel printf). It
            // can never appear in mosh's restored-frame paint (which is local, last-known
            // screen state), so its presence proves the re-homed server is ALIVE.
            // Keying off the sentinel (not "any output after launch-sent") avoids the
            // false positive where the restored frame's own onOutput, dispatched right
            // after onFirstFrame, would otherwise mark a DEAD server alive. Also distinct
            // from `plainTmuxProbeResolved`, which the probe's 2s "assume started" timer
            // flips with no server response.
            if !self.moshReattachSawServerOutput,
               containsPlainTmuxLaunchSentinel(self.plainTmuxProbeBuffer) {
                self.moshReattachSawServerOutput = true
                self.moshReattachWatchdog?.cancel(); self.moshReattachWatchdog = nil
                DebugLog.shared.log(.connect, "resume:reattachMosh SEMICOLYN_LAUNCH seen → server alive, reattach confirmed")
            }
        }
        sess.onFirstFrame = { [weak self] in
            guard let self else { return }
            // Reattach succeeded: frames flowing. Refresh the record (new lastConnectedAt)
            // and drop the in-memory failure copy.
            DebugLog.shared.log(.connect, "resume:reattachMosh onFirstFrame → live")
            self.resumeInMemory = nil
            if isStateResume {
                // Clear the one-shot state blob on EVERY state-resume reattach, independent
                // of whether this record has a tmux session name. If this only ran inside
                // the tmux-name branch below, a state-resume of a non-tmux mosh session
                // would never clear it; a kill before the next background-triggered
                // suspendMoshForBackground() overwrites it would then replay a now-stale
                // Restoration::Context (old crypto seq) on the FOLLOWING reattach, causing
                // the exact server-desync class ("floods stale addr, zero uplink") this
                // feature exists to fix.
                DebugLog.shared.log(.tmux, "resume:reattachMosh state-resume: clearing one-shot blob")
                try? AppStores.shared.moshState.clear(sessionID: record.sessionID)
                // Important-3 safety net: a state-resume paints the restored screen from
                // LOCAL state and fires onFirstFrame off that paint, so "live" here does
                // NOT prove the re-homed server is reachable. If the blob is stale or the
                // server is gone, mosh sits in "Nothing received from server" and NEVER
                // pthread_exits (no onEnd) -> a permanently frozen restored screen.
                //
                // FORCE A FULL REPAINT so the restored screen actually draws AND the
                // liveness check has real output to observe. ROOT CAUSE (vendored mosh,
                // wire+source confirmed 2026-09-13): on RESTORE, mosh reconstructs the true
                // server screen but only writes the minimal DIFF against its `local_framebuffer`
                // (iosclient.cc:320, `new_frame(!repaint_requested, ...)`), which on restore is
                // still BLANK and `repaint_requested` is never set (the upstream `resume()`
                // repaint line is commented out, iosclient.cc:85). We reattach into a fresh
                // BLANK SwiftTerm, so the restored screen is never painted (only a ~13B
                // terminal-open sequence) and an idle session emits nothing further -> frozen
                // screen + the watchdog false-fires a fresh reconnect (device: "instant then
                // full reconnect").
                //
                // mosh's `Ctrl-^ Ctrl-L` (escape-key then 0x0c) sets `repaint_requested = true`
                // (iosclient.cc:377-378, gated on the escape prefix; the BARE-0x0c handler is
                // commented out at :471), forcing `new_frame` to emit the ENTIRE server screen
                // as a fresh paint. That both draws the restored screen for the user AND
                // guarantees a non-empty output chunk that trips the byte-floor liveness check.
                // escape_key defaults to 0x1e with escape_requires_lf=false, so the two-byte
                // 0x1e 0x0c needs no preceding LF (same family as our suspend 0x1e 0x1a and
                // quit 0x1e 0x2e sequences). App-side only, no vendored-mosh change.
                DebugLog.shared.log(.connect, "resume:reattachMosh state-resume: send Ctrl-^ Ctrl-L to force a full repaint")
                sess.writeInput(Data([0x1e, 0x0c]))
                // Arm the liveness watchdog: the paint is the FIRST onOutput chunk; a live
                // re-homed server's redraw output is subsequent chunks past the paint
                // ceiling, which sets moshStateResumeSawServerOutput and cancels this
                // watchdog. On timeout (no server output), fall back to a fresh bootstrap
                // connect. Armed for EVERY state-resume since the freeze afflicts both
                // tmux and non-tmux sessions.
                self.armMoshStateResumeWatchdog(host: host)
            }
            // If the resumed record was a plain-tmux session, RE-LAUNCH tmux in-band and
            // install the gesture controller, exactly like the fresh Mosh path. The
            // reattached login shell is a fresh shell (Mosh reattach re-execs the login
            // shell), so the plain-tmux launch (attach-or-create) lands back in the
            // persisted session and the swipe/zoom/tap gestures work again. Without this,
            // a cold reattach came back as a bare shell with no gestures (device bug
            // 2026-09-04: "Mosh reconnect did not work").
            if let name = record.tmuxSessionName, isValidTmuxSessionName(name) {
                self.tmuxSessionNameForConnection = name
                self.plainTmuxSessionNamePendingInstall = name
                self.installPlainTmuxControllerIfMounted()
                if isStateResume {
                    // State-resume restored the attached-tmux screen verbatim, so re-sending
                    // the plain-tmux launch would re-run inside the restored session. Skip
                    // it: the private gesture bindings persist on the tmux server from the
                    // original launch, so gestures keep working. (Blob already cleared and
                    // the Ctrl-L redraw + watchdog issued above, before this branch.)
                    DebugLog.shared.log(.tmux, "resume:reattachMosh state-resume: skip relaunch (bindings persist on server)")
                } else {
                    self.moshPlainTmuxLaunchSent = true
                    let launch = PlainTmuxController.launchCommand(sessionName: name)
                    DebugLog.shared.log(.tmux, "resume:reattachMosh plainTmux in-band launch \(launch.prefix(60))")
                    self.plainTmuxProbeArmed = true
                    self.plainTmuxProbeBuffer = ""
                    self.plainTmuxProbeResolved = false
                    self.plainTmuxProbeWatchdog?.cancel()
                    self.plainTmuxProbeWatchdog = Task { [weak self] in
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        guard let self, !self.plainTmuxProbeResolved else { return }
                        self.plainTmuxProbeResolved = true
                        DebugLog.shared.log(.tmux, "resume:reattachMosh plainTmux probe window expired inconclusive → assume started")
                    }
                    // Cover the fresh login shell + typed launch until tmux paints.
                    self.beginConnectOverlay()
                    sess.writeInput(Data((launch + "\n").utf8))
                    self.armMoshReattachWatchdog(host: host)
                }
            }
            self.captureResume(host: host, transport: .mosh,
                               endpoint: (host: record.host, port: record.port), secret: key)
        }
        sess.onEnd = { [weak self] reason in
            guard let self else { return }
            // Mutual exclusion with the liveness watchdog (mirrors the fresh path's
            // moshResolved guard): if the watchdog already resolved this reattach (dead
            // server -> fresh connect), a late onEnd must NOT clobber the new connection
            // with a failure banner. `stop()` already nils onEnd, but the flag is the
            // explicit contract.
            if self.moshResolved { return }
            self.moshResolved = true
            DebugLog.shared.log(.connect, "resume:reattachMosh onEnd reason=\(reason ?? "nil") → banner")
            self.moshSession?.stop(); self.moshSession = nil
            self.failResume(host: host, record: record, secret: key,
                            reason: reason ?? "reattach ended")
        }
        moshSession = sess
        sess.start()
        state = .shell
    }

    /// Arm the fresh-relaunch dead-server liveness watchdog: after re-sending
    /// the plain-tmux launch (attach-or-create) on a reattach WITHOUT restored state, require REAL server output
    /// (the SEMICOLYN_LAUNCH sentinel, set in onOutput) within 4s. If none arrives the
    /// stored mosh-server is unreachable -> fall back to a fresh bootstrap connect.
    /// NOT armed on the state-resume path (blob replay is its own success signal).
    private func armMoshReattachWatchdog(host: Host) {
        // Arm the dead-server liveness watchdog: the re-home paints the restored
        // frame + fires onFirstFrame off LOCAL state, so "live" here does NOT mean
        // the server is reachable. Require REAL output in response to the relaunch
        // (set `moshReattachSawServerOutput` in onOutput) within the window; if none
        // arrives the stored mosh-server is gone -> fall back to a fresh bootstrap
        // connect (spawns a new server, provably works) instead of a frozen screen.
        moshReattachSawServerOutput = false
        moshReattachWatchdog?.cancel()
        moshReattachWatchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)   // 4s liveness window
            guard let self, !Task.isCancelled, !self.moshReattachSawServerOutput else { return }
            // Mutual exclusion with onEnd (shared moshResolved flag): claim the
            // resolution so a late onEnd can't also fire a banner over the fresh
            // connect we are about to start.
            if self.moshResolved { return }
            self.moshResolved = true
            DebugLog.shared.log(.connect, "resume:reattachMosh NO live server output in 4s → stored mosh-server dead, fresh reconnect")
            self.moshSession?.stop(); self.moshSession = nil
            self.moshReattachWatchdog = nil
            // Leave `.shell` first: `connect(savedHost:)` IGNORES the call while
            // state is `.shell`/`.connecting` (its re-entry guard), and reattach
            // left us in `.shell`. Flip to `.idle` so the fresh connect proceeds;
            // `connect` immediately tears down + flips to `.connecting`.
            self.state = .idle
            // Full fresh connect (SSH auth -> new mosh bootstrap) using stored
            // creds, the same entry the host list uses; password "" defers to the
            // saved key/credential resolution.
            self.connect(savedHost: host, password: "")
        }
    }

    /// Arm the STATE-resume dead-server liveness watchdog (Important-3 safety net).
    /// Unlike the fresh-relaunch watchdog, a state-resume prints no SEMICOLYN_LAUNCH
    /// sentinel (we skip the plain-tmux launch), so it uses a different signal: reattachMosh forces
    /// a full repaint with Ctrl-^ Ctrl-L, and the server's repaint OUTPUT crossing
    /// `moshStateResumeLivenessFloorBytes` (in onOutput) sets `moshStateResumeSawServerOutput`
    /// and cancels this watchdog. If no repaint arrives within the window (the server is
    /// unreachable, or the stored port is dead), fall back to a fresh bootstrap connect
    /// (spawns a new server) instead of a frozen restored screen. Reuses `moshReattachWatchdog`
    /// (only one reattach watchdog is ever live at a time) and the shared `moshResolved`
    /// mutual-exclusion with onEnd.
    ///
    /// WHY A FORCED REPAINT (device + wire evidence, 2026-09-13): on RESTORE mosh writes only
    /// a ~13B terminal-open sequence and then, for an idle screen, nothing more (it diffs
    /// against a blank local framebuffer and never repaints; see the Ctrl-^ Ctrl-L rationale
    /// in reattachMosh). So there is no server output to observe and the watchdog would
    /// false-fire on every resume. Forcing the repaint gives both the user their restored
    /// screen and this watchdog a real output signal.
    ///
    /// TRADEOFF: a genuinely-alive server that somehow produces no repaint output within the
    /// window would be misjudged dead and trigger a needless fresh reconnect. That reconnect
    /// is non-destructive (re-attaches the SAME persisted session, losing only mosh's local
    /// predictive echo), so a false positive costs a reconnect, never data.
    private func armMoshStateResumeWatchdog(host: Host) {
        moshStateResumeSawServerOutput = false
        moshStateResumeBytesSinceFirstFrame = 0
        moshReattachWatchdog?.cancel()
        // Liveness = onOutput bytes crossing moshStateResumeLivenessFloorBytes: the forced
        // Ctrl-^ Ctrl-L repaint makes the server emit the full screen, which clears the
        // floor and sets moshStateResumeSawServerOutput. If nothing crosses the floor inside
        // the window, the stored server is dead / unreachable -> fresh bootstrap.
        moshReattachWatchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)   // 4s post-onFirstFrame window
            guard let self, !Task.isCancelled, !self.moshStateResumeSawServerOutput else { return }
            // Mutual exclusion with onEnd (shared moshResolved flag): claim the
            // resolution so a late onEnd can't also fire a banner over the fresh connect.
            if self.moshResolved { return }
            self.moshResolved = true
            DebugLog.shared.log(.connect, "resume:reattachMosh state-resume no repaint output in 4s → stored mosh-server dead/blob stale, fresh reconnect")
            self.moshSession?.stop(); self.moshSession = nil
            self.moshReattachWatchdog = nil
            // Leave `.shell` first (connect() ignores the call while `.shell`), same as
            // the fresh-relaunch watchdog; connect() then tears down + flips to
            // `.connecting`, which also resets the state-resume flags via teardown().
            self.state = .idle
            self.connect(savedHost: host, password: "")
        }
    }

    /// Handle a failed cold reattach: clear the persisted record (dead token) but keep
    /// the reattach info IN MEMORY so the banner's Retry works, then show the banner.
    private func failResume(host: Host, record: ResumableSession, secret: Data, reason: String) {
        AppStores.shared.resume.clear(sessionID: record.sessionID)
        resumeInMemory = (host: host, record: record, secret: secret)
        // Set the banner label BEFORE flipping to .idle: SessionView's `.onChange(state)`
        // dismisses on .idle ONLY when `resumeFailure == nil`, so the banner must be
        // armed first or the cover would dismiss before the user can act.
        resumeFailure = host.label
        state = .idle   // no live shell; the banner drives the next action
        DebugLog.shared.log(.connect, "resume:fail host=\(host.label) reason=\(reason) → banner (record cleared, in-mem kept)")
    }

    // MARK: - Resume banner + raw-prompt actions

    /// Banner Retry: re-attempt the cold reattach from the in-memory copy.
    func resumeRetry() {
        guard let mem = resumeInMemory else { return }
        DebugLog.shared.log(.connect, "resume:retry host=\(mem.host.label)")
        resumeFailure = nil
        // Re-persist the in-memory secret so the reattach path can read it, then re-run.
        AppStores.shared.resume.captureConnected(
            sessionID: mem.record.sessionID, host: mem.host, transport: mem.record.transport,
            endpoint: (host: mem.record.host, port: mem.record.port),
            secret: mem.secret, tmuxSessionName: mem.record.tmuxSessionName)
        resumeColdReattach(host: mem.host, record: mem.record)
    }

    /// Banner Start fresh: a NEW connection to the same host (explicit new session).
    func resumeStartFresh() {
        guard let mem = resumeInMemory else { return }
        DebugLog.shared.log(.connect, "resume:startFresh host=\(mem.host.label)")
        resumeFailure = nil
        resumeInMemory = nil
        connect(savedHost: mem.host, password: lastPassword ?? "")
    }

    /// Banner Back to hosts: drop the in-memory copy and dismiss to the host list.
    func resumeBackToHosts() {
        DebugLog.shared.log(.connect, "resume:backToHosts")
        resumeFailure = nil
        resumeInMemory = nil
        state = .idle
    }

    /// Raw-SSH prompt Reconnect: a fresh SSH connect to the same host. `connect`
    /// clears the old record (teardown) and mints a fresh session id.
    func resumeRawReconnect(host: Host) {
        DebugLog.shared.log(.connect, "resume:rawReconnect host=\(host.label)")
        resumeRawPrompt = nil
        resumeRawRecord = nil
        connect(savedHost: host, password: lastPassword ?? "")
    }

    /// Raw-SSH prompt Not now: clear the resumed record and dismiss to the host list.
    func resumeRawDecline(host: Host) {
        DebugLog.shared.log(.connect, "resume:rawDecline host=\(host.label)")
        resumeRawPrompt = nil
        if let rec = resumeRawRecord {
            AppStores.shared.resume.clear(sessionID: rec.sessionID)
        }
        resumeRawRecord = nil
        state = .idle
    }

    // MARK: - Auth

    /// Authenticate `conn` for `host`: if the host references a stored identity
    /// whose private key is available, use publickey; otherwise fall back to the
    /// supplied password. Returns the outcome; the caller maps non-success to a
    /// `.failed` state.
    ///
    /// Publickey-present-but-rejected is NOT silently promoted to password auth,
    /// the outcome is returned as-is (matches the cert-auth no-fallback rule).
    private func authenticate(conn: Connection, user: String, host: Host,
                              defaults: Defaults, password: String) async throws -> AuthOutcome {
        // Resolve the identity through Defaults inheritance, not just the host's explicit value.
        if let identityID = resolveIdentities(host: host, defaults: defaults).first {
            // A genuine Keychain read failure must surface (no `try?`); only a truly
            // absent private key falls back to password (e.g. SE-flavor identity whose
            // key isn't stored on this device).
            if let key = try AppStores.shared.identities.privateKeyOpenSSH(for: identityID) {
                // No silent fallback: a present-but-rejected key returns its outcome.
                DebugLog.shared.log(.connect, "authenticate: publickey (identity=\(identityID))")
                let outcome = try await conn.authenticatePublickey(user: user, privateKeyOpenssh: key)
                DebugLog.shared.log(.connect, "authenticate: publickey → \(String(describing: outcome))")
                return outcome
            }
            DebugLog.shared.log(.connect, "authenticate: identity \(identityID) has no stored key → password fallback")
        } else {
            DebugLog.shared.log(.connect, "authenticate: no identity resolved → password")
        }
        let outcome = try await conn.authenticatePassword(user: user, password: password)
        DebugLog.shared.log(.connect, "authenticate: password → \(String(describing: outcome))")
        return outcome
    }

    // MARK: - Host record

    /// Find an existing saved host matching (hostName, user) or create + persist one.
    private func findOrCreateHost(hostName: String, port: Int, user: String) throws -> Host {
        let existing = try AppStores.shared.hosts.allHosts()
            .first { $0.hostName == hostName && ($0.port.value ?? 22) == port && $0.user.value == user }
        if let existing { return existing }
        let host = Host(id: UUID(), label: hostName, hostName: hostName,
                        user: .explicit(user), port: .explicit(port))
        try AppStores.shared.hosts.saveHost(host)
        return host
    }

    /// Present the confirm-and-connect sheet for a tapped ssh:// link. Parses the
    /// URL and silently ignores anything that isn't a usable ssh:// target, a tap
    /// never connects on its own (Phase-3c ssh:// link seam).
    func presentSSHLink(_ url: URL) {
        guard let target = parseSSHURL(url.absoluteString) else { return }
        presentedSheet = .quickConnect(target)
    }

    /// Find an existing saved host matching an ssh:// target, or create + persist one.
    /// A target without a user inherits the default user (`.inherit`).
    func hostForSSHTarget(_ target: SSHConnectTarget) throws -> Host {
        let port = target.port ?? 22
        let existing = try AppStores.shared.hosts.allHosts()
            .first { $0.hostName == target.host && ($0.port.value ?? 22) == port && $0.user.value == target.user }
        if let existing { return existing }
        let host = Host(id: UUID(), label: target.host, hostName: target.host,
                        user: target.user.map { Inherited.explicit($0) } ?? .inherit,
                        port: .explicit(port))
        try AppStores.shared.hosts.saveHost(host)
        return host
    }

    // MARK: - Shell paths

    /// Run `tmux -V` over a one-shot exec and return its stdout (nil if nothing
    /// came back or the channel failed). Resolves when the exec channel closes.
    private func probeTmuxVersion(conn: Connection) async -> String? {
        let sink = TerminalShellOutput()
        var captured: [UInt8] = []
        sink.onBytes = { captured.append(contentsOf: $0) }
        let done = AsyncStream<Void> { cont in
            sink.onExit = { _ in cont.yield(); cont.finish() }
        }
        let probeSession = try? await conn.openExec(command: "tmux -V", term: "xterm-256color",
                                                    cols: 80, rows: 24, output: sink)
        guard probeSession != nil else {
            DebugLog.shared.log(.tmux, "probeTmuxVersion: exec FAILED to open → nil")
            return nil
        }
        defer { if let probeSession { Task { try? await probeSession.close() } } }
        // Race the exec-channel close against a 2-second guard in case onExit
        // is never fired (e.g. some server implementations don't send channel EOF
        // on exec exit).
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await _ in done { break }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            await group.next()
            group.cancelAll()
        }
        let text = String(decoding: captured, as: UTF8.self)
        DebugLog.shared.log(.tmux, "probeTmuxVersion: got \(text.isEmpty ? "EMPTY (nil)" : text.trimmingCharacters(in: .whitespacesAndNewlines))")
        return text.isEmpty ? nil : text
    }

    /// Open a raw PTY shell: the original pre-tmux path. Sets `connection`,
    /// `session`, and `state = .shell`.
    private func openRawShell(conn: Connection) async throws {
        DebugLog.shared.log(.lifecycle, "openRawShell: opening PTY shell")
        let sess = try await conn.openShell(
            term: "xterm-256color", cols: 80, rows: 24, output: output)
        connection = conn
        session = sess
        rawWriter = SerialByteWriter(sink: ShellSessionSink(session: sess))
        output.onHarvestBytes = { [weak self] bytes in
            guard let self else { return }
            // Feed output to the password-prompt gate only. We deliberately no longer
            // harvest free terminal output as suggestion candidates, that pulled the
            // shell prompt (Starship) into suggestions. Suggestions now source from
            // typed-command echo (record) + seed only. (predictor-suggestion-hygiene spec, Fix 1.)
            self.passwordDetector.noteOutput(bytes)
        }
        DebugLog.shared.log(.lifecycle, "openRawShell: shell opened, state=.shell")
        state = .shell
    }

    /// Probe tmux on the authenticated connection and launch plain tmux or fall
    /// back to a degraded raw shell. This is the shared SSH tail of
    /// both `connect` methods, factored out so the Mosh pre-frame fallback can re-run
    /// it on the SAME retained connection (see `attachMoshIfPossible`).
    private func attachSSHShell(conn: Connection, host: Host, defaults: Defaults) async throws {
        // Gesture-driven plain tmux is the only tmux route: whether to attempt it
        // at all is a per-host/default choice (`resolveUseTmux`), not a debug gate.
        let useTmux = resolveUseTmux(host: host, defaults: defaults)
        let probe = useTmux ? await probeTmuxVersion(conn: conn) : nil
        DebugLog.shared.log(.lifecycle, "attachSSHShell: useTmux=\(useTmux) probe=\(probe ?? "nil")")
        switch tmuxLaunchDecision(useTmux: useTmux, versionProbe: probe) {
        case .attach:
            self.tmuxSessionNameForConnection = resolveTmuxSessionName(host: host, defaults: defaults)
            try await attachPlainTmux(conn: conn)
        case .degrade(let reason):
            DebugLog.shared.log(.lifecycle, "attachSSHShell: decision=DEGRADE(\(String(describing: reason))) -> raw shell")
            degraded = reason
            try await openRawShell(conn: conn)
        }
        // Connected edge (raw SSH / gesture-tmux over SSH): a raw SSH session is
        // client-side, so it resumes by PROMPTING (transport = .ssh, no secret). The
        // tmux session name always rides so a confirmed fresh reconnect lands back
        // in the same session via the plain-tmux launch (attach-or-create).
        // Runs on the main actor (async method on a @MainActor class), no wrap needed.
        captureResume(host: host, transport: .ssh,
                      endpoint: (host: host.hostName, port: resolvePort(host: host, defaults: defaults)),
                      secret: nil)
    }

    // MARK: - Mosh path

    /// Run the `mosh-server` bootstrap over a one-shot exec and return its stdout
    /// (empty string if nothing came back or the channel failed). Resolves when the
    /// exec channel closes or a 2s guard fires, same race as `probeTmuxVersion`.
    private func captureMoshBootstrap(conn: Connection, command: String) async -> String {
        let sink = TerminalShellOutput()
        var captured: [UInt8] = []
        sink.onBytes = { captured.append(contentsOf: $0) }
        let done = AsyncStream<Void> { cont in
            sink.onExit = { _ in cont.yield(); cont.finish() }
        }
        let sess = try? await conn.openExec(command: command, term: "xterm-256color",
                                            cols: 80, rows: 24, output: sink)
        guard sess != nil else {
            DebugLog.shared.log(.connect, "mosh: bootstrap exec FAILED to open (openExec returned nil)")
            return ""
        }
        defer { if let sess { Task { try? await sess.close() } } }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { for await _ in done { break } }
            group.addTask { try? await Task.sleep(nanoseconds: 2_000_000_000) }
            await group.next(); group.cancelAll()
        }
        return String(decoding: captured, as: UTF8.self)
    }

    /// Attach a Mosh session on the authenticated connection: bootstrap mosh-server,
    /// decide, and either create a `MoshSession` or fall back to the SSH/tmux path
    /// with a banner. Returns true if a Mosh session was attached; false if it fell
    /// back (the caller then runs the existing tmux/raw branch).
    private func attachMoshIfPossible(conn: Connection, host: Host, defaults: Defaults) async -> Bool {
        // Both call sites are already inside `case .mosh:` of a `switch
        // resolveTransport(host:defaults:)`, so the transport picker (or its
        // legacy mosh.enabled migration) already decided Mosh is the transport
        // for this connection. No separate `resolveMoshEnabled` gate here.
        DebugLog.shared.log(.connect, "connect:mosh chosen by transport picker (resolveTransport==.mosh)")
        // DIRECT launch: with plain tmux on, mosh-server runs the tmux launch as its
        // SESSION COMMAND (`mosh-server new ... -- <plainTmuxDirectLaunchCommand>`)
        // instead of a login shell, so the user's interactive shell startup and the
        // typed/echoed launch line never appear. The launch is UNCONDITIONAL whenever
        // `useTmux` is on: there is no pre-frame exec channel over Mosh to probe
        // `tmux -V` the way SSH's `probeTmuxVersion` does. If tmux is not on the
        // non-interactive PATH, the direct script prints `SEMICOLYN_NOTMUX` and execs
        // the user's login shell; `onOutput` below then falls back ONCE to today's
        // in-band launch typed into that shell (whose rc files may add tmux to PATH).
        // If that also fails, the reactive probe (`evaluatePlainTmuxProbe`) degrades
        // gracefully. Detaching/exiting tmux leaves the user at their login shell.
        let useTmux = resolveUseTmux(host: host, defaults: defaults)
        var directLaunchCommand: String?
        if useTmux {
            self.tmuxSessionNameForConnection = resolveTmuxSessionName(host: host, defaults: defaults)
            DebugLog.shared.log(.lifecycle, "mosh: useTmux=ON session=\(tmuxSessionNameForConnection) (unconditional launch)")
            if isValidTmuxSessionName(tmuxSessionNameForConnection) {
                directLaunchCommand = plainTmuxDirectLaunchCommand(sessionName: tmuxSessionNameForConnection)
                DebugLog.shared.log(.tmux, "mosh: direct launch session=\(tmuxSessionNameForConnection)")
            }
        }
        moshDirectLaunch = directLaunchCommand != nil
        moshDirectLaunchFallbackSent = false
        moshDirectLaunchOutput = ""
        // Effective config for the argv (port range, server path, prediction mode).
        // resolveOptional honors Inherited three-state (NOT host.mosh.value).
        let cfg = resolveOptional(host.mosh, defaults.mosh) ?? MoshConfig(enabled: true)
        let command = moshServerCommand(cfg, sessionCommand: directLaunchCommand).joined(separator: " ")
        let stdout = await captureMoshBootstrap(conn: conn, command: command)
        DebugLog.shared.log(.connect, "mosh: bootstrap captured \(stdout.count)B")
        switch moshBranchOutcome(stdout: stdout, enabled: true) {
        case let .mosh(port, key):
            DebugLog.shared.log(.connect, "mosh: bootstrap OK port=\(port) keyLen=\(key.count) → starting UDP session")
            // mosh-client's getaddrinfo uses AI_NUMERICHOST (numeric IP only, NO DNS),
            // so it rejects a hostname. Resolve host.hostName to a numeric IP here
            // (SSH already reached the host, so it resolves). If we can't resolve, don't
            // hand mosh a name it will reject, fall back to SSH with a clear reason.
            guard let moshIP = MoshHostResolver.numericAddress(for: host.hostName) else {
                DebugLog.shared.log(.connect, "mosh: could not resolve \(host.hostName) to an IP → SSH fallback")
                moshFallback = "Mosh: couldn't resolve \(host.hostName), using SSH"
                return false
            }
            DebugLog.shared.log(.connect, "mosh: resolved \(host.hostName) → \(moshIP)")
            let predict = cfg.predictionMode?.rawValue ?? "adaptive"
            // Seeded at 80×24: the terminal view hasn't laid out yet at connect time,
            // so the real grid isn't known here. The first debounced resize from
            // TerminalScreen (via setMoshClientSize) corrects it once layout happens,
            // and mosh reflows. FUTURE (item #5 Q2(b)): to skip the brief 80×24 first
            // frame, track the last-known terminal grid on the VM and pass it here.
            let sess = MoshSession(ip: moshIP, port: String(port), key: key,
                                   cols: 80, rows: 24, predictMode: predict)
            // Reset the handshake gate: onEnd before the first frame means the UDP
            // handshake never completed → fall back to SSH on the retained connection;
            // onEnd after a frame is a genuine mid-session exit → crash banner.
            moshFirstFrameSeen = false
            // Route Mosh output through the SAME buffered entry point as the Rust
            // SSH path (`output.onOutput`) rather than calling the stored `onBytes`
            // sink directly. Mosh's first framebuffer diff is emitted synchronously
            // during `sess.start()`, before `state = .shell` triggers SwiftUI's
            // `makeUIView`, which is what installs the render sink, so a direct
            // `onBytes?` call would silently drop that frame (nil sink → no-op) and
            // leave the terminal permanently blank. `onOutput` appends to the
            // `PendingOutputBuffer`, which replays on sink-install. (Harvest stays
            // off the Mosh path: `onHarvestBytes` is never installed here, so its
            // pass in `onOutput` is a no-op.)
            sess.onOutput = { [weak self] data in
                guard let self else { return }
                self.output.onOutput(data: data)
                // Connecting overlay: runs after the probe accumulation below (on every
                // exit path) so the sentinel check sees this chunk.
                defer { self.noteConnectOverlayOutput() }
                // Direct launch: tmux was not on mosh-server's non-interactive PATH, so the
                // script printed the marker and exec'd the user's login shell. Fall back
                // ONCE to the in-band launch typed into that shell. Checked BEFORE the probe
                // accumulation, which stops once the sentinel (printed before the marker)
                // is seen. Returns without adding this chunk to the re-armed probe buffer:
                // it carries the DIRECT launch's sentinel, which must not count as the
                // in-band launch's.
                if self.moshDirectLaunch, !self.moshDirectLaunchFallbackSent,
                   self.moshDirectLaunchOutput.utf8.count < 16384 {
                    self.moshDirectLaunchOutput += String(decoding: data, as: UTF8.self)
                    if containsPlainTmuxNoTmuxMarker(self.moshDirectLaunchOutput) {
                        self.moshDirectLaunchFallbackSent = true
                        self.moshDirectLaunchOutput = ""
                        DebugLog.shared.log(.tmux, "mosh: direct launch printed \(plainTmuxNoTmuxMarker) (tmux not on non-interactive PATH) → in-band launch fallback in login shell session=\(self.tmuxSessionNameForConnection)")
                        self.startMoshPlainTmuxLaunch(sess: sess, typeInBandLaunch: true)
                        return
                    }
                }
                // Reactive tmux-missing detector (see `evaluatePlainTmuxProbe`): accumulate
                // per `shouldAccumulatePlainTmuxProbe`.
                guard self.shouldAccumulatePlainTmuxProbe else { return }
                self.plainTmuxProbeBuffer += String(decoding: data, as: UTF8.self)
                self.evaluatePlainTmuxProbe()
            }
            sess.onFirstFrame = { [weak self] in
                // Frames are flowing: the UDP path is up. `moshFirstFrameSeen` is no
                // longer the exit discriminator (that's reason+elapsed now), but it
                // still records that a frame arrived; cancelling the watchdog here is
                // the important effect, the loop signalled life, so don't SSH-fall-back.
                DebugLog.shared.log(.connect, "mosh: onFirstFrame, UDP handshake up, frames flowing")
                self?.moshFirstFrameSeen = true
                self?.moshWatchdog?.cancel(); self?.moshWatchdog = nil
                DebugLog.shared.log(.connect, "mosh: watchdog cancelled (onFirstFrame)")
                // Start the plain-tmux launch (attach-or-create) now that frames are
                // flowing. DIRECT launch: mosh-server is already running it as the session
                // command, so only the app side runs (controller, probe, overlay) and
                // nothing is typed. Otherwise type it IN-BAND into the login shell, like
                // ET. Guarded by `moshPlainTmuxLaunchSent` (idempotency; `onFirstFrame` is
                // documented once-only, but this makes the launch robust either way).
                // Use the captured `sess` (not `self.moshSession`): `onFirstFrame` can
                // fire SYNCHRONOUSLY during `sess.start()` below (see the `onOutput`
                // comment above), before `moshSession = sess` runs, so `self.moshSession`
                // may still be nil at this instant.
                if useTmux, let self, !self.moshPlainTmuxLaunchSent,
                   isValidTmuxSessionName(self.tmuxSessionNameForConnection) {
                    self.moshPlainTmuxLaunchSent = true
                    self.startMoshPlainTmuxLaunch(sess: sess, typeInBandLaunch: !self.moshDirectLaunch)
                }
                // Connected edge: persist the resume record. Reattach endpoint is the
                // Mosh server (host + UDP port); secret is the MOSH_KEY. Runs AFTER the
                // plain-tmux install above so `isTmuxSession` (reads `plainTmux != nil`)
                // is true for a plain-tmux Mosh session, and the tmux session name RIDES
                // the record so a cold reattach lands back in the tmux session rather
                // than a raw shell (device bug 2026-09-04: Mosh resume captured tmux=false).
                self?.captureResume(host: host, transport: .mosh,
                                    endpoint: (host: host.hostName, port: port),
                                    secret: Data(key.utf8))
            }
            // Stamp the start time BEFORE the onEnd closure literal so the closure can
            // capture it (Swift resolves captures at declaration order, not runtime).
            // The session can't fire onEnd before sess.start() below, so this is the
            // true session-start instant. Monotonic clock (systemUptime).
            let moshStartedAt = ProcessInfo.processInfo.systemUptime
            sess.onEnd = { [weak self] reason in
                guard let self else { return }
                self.moshWatchdog?.cancel(); self.moshWatchdog = nil
                // The watchdog may have already resolved this session (attached SSH)
                // via an onEnd dispatch that was enqueued before the watchdog niled it.
                // Bail so we don't clobber the watchdog's SSH shell with a stale banner.
                if self.moshResolved {
                    DebugLog.shared.log(.connect, "mosh: onEnd after watchdog already resolved → ignored")
                    return
                }
                self.moshResolved = true
                DebugLog.shared.log(.connect, "mosh: onEnd firstFrameSeen=\(self.moshFirstFrameSeen) reason=\(reason ?? "nil")")
                let elapsed = ProcessInfo.processInfo.systemUptime - moshStartedAt
                switch moshExitDecision(reason: reason, elapsed: elapsed) {
                case .crashBanner:
                    self.moshSession?.stop()
                    self.moshSession = nil
                    self.moshFirstFrameSeen = false
                    // Mid-flight error: the session broke, the MOSH_KEY is likely stale.
                    // Clear the resume record (this path does NOT call teardown).
                    self.clearResume()
                    DebugLog.shared.log(.connect, "mosh: exit crashBanner (elapsed=\(String(format: "%.2f", elapsed))s) → crash banner")
                    self.crashBanner = .tmuxEnded
                    return
                case .ended:
                    // Clean exit (rc == 0). v1: surface via the same session-ended state
                    // as a clean tmux exit (no alarming "crashed" copy needed).
                    self.moshSession?.stop()
                    self.moshSession = nil
                    self.moshFirstFrameSeen = false
                    // Session over (clean exit): clear the resume record (no teardown here).
                    self.clearResume()
                    DebugLog.shared.log(.connect, "mosh: exit ended (clean, elapsed=\(String(format: "%.2f", elapsed))s) → session ended")
                    self.crashBanner = .tmuxEnded
                    return
                case .fallbackSSH:
                    self.moshSession?.stop()
                    self.moshSession = nil
                    // Surface the REAL reason captured from mosh's stderr (e.g.
                    // "Mosh failed: Crypto: …, using SSH") when we have it; the bridge
                    // falls back to a generic string only when nothing was captured.
                    self.moshFallback = reason ?? "Mosh connection failed, using SSH"
                    DebugLog.shared.log(.connect, "mosh: exit fallbackSSH (elapsed=\(String(format: "%.2f", elapsed))s) → SSH fallback")
                    // The Mosh session the overlay was covering is gone.
                    self.evaluateConnectReveal(sessionEnded: true)
                    Task { [weak self] in
                        guard let self else { return }
                        do {
                            try await self.attachSSHShell(conn: conn, host: host, defaults: defaults)
                        } catch {
                            DebugLog.shared.log(.connect, "mosh: SSH fallback THREW \(String(describing: error)) → .failed")
                            self.state = .failed(String(describing: error))
                        }
                    }
                }
            }
            DebugLog.shared.log(.connect, "mosh: sess.start(), UDP session launching, state=.shell")
            sess.start()
            moshSession = sess
            connection = conn
            moshWatchdog = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 10_000_000_000)   // 10s watchdog window
                guard !Task.isCancelled, let self else { return }
                // No onFirstFrame/onEnd cancelled us → the loop signalled no life.
                guard case .fallbackSSH = moshWatchdogAction(sawAnyCallback: false) else { return }
                // Claim the resolution before the attachSSHShell suspension point so a
                // late onEnd (enqueued before we niled the callback) bails instead of
                // clobbering this SSH shell.
                if self.moshResolved { return }
                self.moshResolved = true
                DebugLog.shared.log(.connect, "mosh: watchdog fired (no frame/exit in 10s) → SSH fallback")
                self.moshSession?.stop()
                self.moshSession = nil
                self.moshFallback = "Mosh didn't connect, using SSH"
                do {
                    try await self.attachSSHShell(conn: conn, host: host, defaults: defaults)
                } catch {
                    DebugLog.shared.log(.connect, "mosh: watchdog SSH fallback THREW \(String(describing: error)) → .failed")
                    self.state = .failed(String(describing: error))
                }
            }
            state = .shell
            return true
        case let .fallback(reason):
            DebugLog.shared.log(.connect, "mosh: bootstrap FALLBACK (\(reason)) → caller runs SSH/tmux")
            moshFallback = reason   // pre-handoff banner; caller runs the SSH/tmux path
            return false
        }
    }

    /// The app side of a fresh Mosh plain-tmux launch: install the gesture controller,
    /// arm the reactive tmux-missing probe, raise the connecting overlay and, when
    /// `typeInBandLaunch`, type the in-band launch (attach-or-create) into the login
    /// shell. Called from `onFirstFrame` (`typeInBandLaunch` false under the direct
    /// launch, where mosh-server already runs it) and once from `onOutput` when the
    /// direct launch reports tmux missing from its PATH (the in-band fallback). Takes the
    /// captured `sess`, since `moshSession` may still be nil during `sess.start()`.
    private func startMoshPlainTmuxLaunch(sess: MoshSession, typeInBandLaunch: Bool) {
        let name = tmuxSessionNameForConnection
        if typeInBandLaunch {
            DebugLog.shared.log(.tmux, "mosh: plainTmux in-band launch \(PlainTmuxController.launchCommand(sessionName: name).prefix(60))")
        } else {
            DebugLog.shared.log(.tmux, "mosh: plainTmux direct launch running as the session command, nothing typed")
        }
        // Install the gesture controller NOW against the already-mounted view.
        // The raw `TerminalView` mounted before this UDP first-frame (it mounts
        // to receive Mosh output), so `TerminalScreen.makeUIView` already ran its
        // one-time `installPlainTmuxControllerIfNeeded` while the pending name was
        // still nil (a no-op) and never runs again. Setting the pending name here
        // and immediately calling `installPlainTmuxControllerIfMounted()` builds
        // the controller against the stashed view, so `vm.plainTmux != nil` and
        // the swipe/zoom/tap gestures route through it (device bug 2026-09-04:
        // Mosh gestures never installed -> swipe fell through to alt-screen
        // scroll). Idempotent on the fallback (controller already installed).
        plainTmuxSessionNamePendingInstall = name
        installPlainTmuxControllerIfMounted()
        // Arm the reactive tmux-missing probe: Mosh can't pre-probe
        // `tmux -V` (no pre-frame exec channel), so watch the first
        // ~2s of output and classify it (see `evaluatePlainTmuxProbe`).
        plainTmuxProbeArmed = true
        plainTmuxProbeBuffer = ""
        plainTmuxProbeResolved = false
        plainTmuxProbeWatchdog?.cancel()
        plainTmuxProbeWatchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)   // 2s probe window
            guard let self, !self.plainTmuxProbeResolved else { return }
            // Window expired inconclusive: bias toward NOT tearing down a
            // working session (a false `.tmuxMissing` would be disruptive;
            // a missed one just leaves inert-but-harmless gestures).
            self.plainTmuxProbeResolved = true
            DebugLog.shared.log(.tmux, "mosh: plainTmux probe window expired inconclusive → assume started")
        }
        // Cover the login shell / typed launch until tmux paints (launch time = now).
        beginConnectOverlay()
        guard typeInBandLaunch else { return }
        sess.writeInput(Data((PlainTmuxController.launchCommand(sessionName: name) + "\n").utf8))
    }

    // MARK: - ET path

    /// Run the ET bootstrap over a one-shot exec and return its stdout, or nil if
    /// the exec channel could not be opened. Resolves when the exec closes or a 2s
    /// guard fires (same race as `captureMoshBootstrap`). SECURITY: the command
    /// contains the passkey; never log `command` verbatim.
    private func captureETBootstrap(conn: Connection, command: String) async -> String? {
        let sink = TerminalShellOutput()
        var captured: [UInt8] = []
        sink.onBytes = { captured.append(contentsOf: $0) }
        let done = AsyncStream<Void> { cont in
            sink.onExit = { _ in cont.yield(); cont.finish() }
        }
        guard let sess = try? await conn.openExec(command: command, term: "xterm-256color",
                                                   cols: 80, rows: 24, output: sink) else {
            DebugLog.shared.log(.connect, "et: bootstrap exec FAILED to open (openExec returned nil)")
            return nil
        }
        defer { Task { try? await sess.close() } }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { for await _ in done { break } }
            group.addTask { try? await Task.sleep(nanoseconds: 2_000_000_000) }
            await group.next(); group.cancelAll()
        }
        let out = String(decoding: captured, as: UTF8.self)
        DebugLog.shared.log(.transport, "et: bootstrap payload " + maskBootstrapPayload(out))
        return out
    }

    /// Bootstrap + attach an ET session on the authenticated connection. Returns
    /// `.success` when the `ETSession` started; `.failure(ETBootstrapError)`
    /// otherwise. Does NOT fall back to SSH (per the ET-bootstrap design: the
    /// fallback/UI slice renders the error). TEMPORARY: reached only via a
    /// dev-only entry point until the Transport picker (§5) wires real routing;
    /// the existing Mosh-silently-wins routing in `attachMoshIfPossible` is
    /// untouched. SECURITY: never log the passkey, the bootstrap `command`
    /// string, or the raw IDPASSKEY line, only lengths / parsed-ok-or-failed.
    private func attachET(conn: Connection, host: Host, defaults: Defaults) async -> Result<Void, ETBootstrapError> {
        let cred = etGenerateCredential()
        let term = "xterm-256color"
        let command = etBootstrapCommand(id: cred.id, passkey: cred.passkey, term: term)
        DebugLog.shared.log(.connect, "et: bootstrap exec (idLen=\(cred.id.count) keyLen=\(cred.passkey.count))")

        guard let stdout = await captureETBootstrap(conn: conn, command: command) else {
            return .failure(.execFailed)
        }
        DebugLog.shared.log(.transport, "et: parse input " + maskBootstrapPayload(stdout))
        let serverCred: ETCredential
        switch parseETIDPASSKEY(stdout) {
        case .success(let cred):
            serverCred = cred
        case .failure(let e):
            DebugLog.shared.log(.connect, "et: IDPASSKEY parse FAILED (\(String(describing: e)))")
            return .failure(e)
        }
        DebugLog.shared.log(.connect, "et: IDPASSKEY parsed ok")

        // Seeded at 80×24 like the Mosh path (see attachMoshIfPossible): the
        // terminal view hasn't laid out yet at connect time, so the real grid
        // isn't known here.
        let cols: UInt16 = 80, rows: UInt16 = 24
        let config: ETConfig
        do {
            config = try etConnectConfig(host: host.hostName, id: serverCred.id,
                                         passkey: serverCred.passkey, term: term,
                                         cols: cols, rows: rows)
        } catch let e as ETConfigError {
            DebugLog.shared.log(.connect, "et: config invalid (\(String(describing: e)))")
            return .failure(.invalidConfig(e))
        } catch {
            DebugLog.shared.log(.connect, "et: config build threw unexpected error → malformedIDPASSKEY")
            return .failure(.malformedIDPASSKEY)
        }

        let sess = ETSession(host: config.host, port: config.port, id: config.id,
                             passkey: config.passkey, env: config.env,
                             cols: config.cols, rows: config.rows,
                             width: config.width, height: config.height,
                             keepaliveSecs: config.keepaliveSecs)

        // ET, like Mosh, attaches a login shell with no launch-command argument, so
        // "launch plain tmux" means sending the plain-tmux launch (attach-or-create) IN-BAND once
        // the stream is up (see `onFirstFrame` below). `resolveUseTmux` is the SOLE
        // gesture-vs-plain-shell toggle. ET can't pre-probe `tmux -V` (etserver spawns the
        // login shell; there is no pre-shell exec), so like Mosh the launch is
        // UNCONDITIONAL whenever `useTmux` is on; reactive detection
        // (`evaluatePlainTmuxProbe` below) watches the first output and degrades
        // gracefully if tmux isn't actually installed remotely.
        let useTmux = resolveUseTmux(host: host, defaults: defaults)
        if useTmux {
            self.tmuxSessionNameForConnection = resolveTmuxSessionName(host: host, defaults: defaults)
            DebugLog.shared.log(.lifecycle, "et: useTmux=ON session=\(tmuxSessionNameForConnection) (unconditional in-band launch on first frame)")
        }

        // Route ET output through the SAME buffered entry point the Mosh path uses
        // (`output.onOutput`): the `PendingOutputBuffer` behind `onOutput` replays on
        // sink-install, so an early frame (before SwiftUI's `makeUIView` installs the
        // render sink) isn't silently dropped.
        etResolved = false
        sess.onOutput = { [weak self] data in
            guard let self else { return }
            self.output.onOutput(data: data)
            // Connecting overlay: runs after the probe accumulation below (on every exit
            // path) so the sentinel check sees this chunk.
            defer { self.noteConnectOverlayOutput() }
            // Reactive tmux-missing detector (see `evaluatePlainTmuxProbe`): accumulate
            // per `shouldAccumulatePlainTmuxProbe`.
            guard self.shouldAccumulatePlainTmuxProbe else { return }
            self.plainTmuxProbeBuffer += String(decoding: data, as: UTF8.self)
            self.evaluatePlainTmuxProbe()
        }
        sess.onFirstFrame = { [weak self] in
            guard let self, !self.etResolved else { return }
            self.etResolved = true
            self.etFirstFrameSeen = true
            self.etWatchdog?.cancel(); self.etWatchdog = nil
            DebugLog.shared.log(.transport, "et: onFirstFrame, stream up; watchdog cancelled")
            self.state = .shell
            // Plain-tmux in-band launch.
            // Install the gesture controller against the already-mounted view HERE (the
            // in-band launch happens after `TerminalScreen.makeUIView`'s one-time install
            // already no-op'd, so relying on makeUIView never installs it: device bug
            // 2026-09-04).
            if useTmux, !self.etPlainTmuxLaunchSent,
               isValidTmuxSessionName(self.tmuxSessionNameForConnection) {
                self.etPlainTmuxLaunchSent = true
                let launch = PlainTmuxController.launchCommand(sessionName: self.tmuxSessionNameForConnection)
                DebugLog.shared.log(.tmux, "et: plainTmux in-band launch \(launch.prefix(60))")
                self.plainTmuxSessionNamePendingInstall = self.tmuxSessionNameForConnection
                // Install the gesture controller against the already-mounted view now:
                // like Mosh, ET launches in-band on onFirstFrame AFTER makeUIView's
                // one-time install already no-op'd, so it must install here (device bug
                // 2026-09-04). No-op on SSH (installed at makeUIView).
                self.installPlainTmuxControllerIfMounted()
                // Arm the reactive tmux-missing probe: ET can't pre-probe `tmux -V`
                // (no pre-shell exec), so watch the first ~2s of output and classify
                // it (see `evaluatePlainTmuxProbe`).
                self.plainTmuxProbeArmed = true
                self.plainTmuxProbeBuffer = ""
                self.plainTmuxProbeResolved = false
                self.plainTmuxProbeWatchdog?.cancel()
                self.plainTmuxProbeWatchdog = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)   // 2s probe window
                    guard let self, !self.plainTmuxProbeResolved else { return }
                    // Window expired inconclusive: bias toward NOT tearing down a
                    // working session (a false `.tmuxMissing` would be disruptive;
                    // a missed one just leaves inert-but-harmless gestures).
                    self.plainTmuxProbeResolved = true
                    DebugLog.shared.log(.tmux, "et: plainTmux probe window expired inconclusive → assume started")
                }
                // Cover the login shell + typed launch until tmux paints.
                self.beginConnectOverlay()
                sess.send(Data((launch + "\n").utf8))
            }
            // Connected edge: persist the resume record. Runs AFTER the plain-tmux install
            // above (so `isTmuxSession` reads `plainTmux != nil` and the tmux session name
            // rides the record, matching the Mosh path). Reattach endpoint is the ET
            // server (config.host + TCP port); secret is the IDPASSKEY (`<id>/<passkey>`,
            // the wire form parseETIDPASSKEY reads). NOTE: ET has no cold-reattach today,
            // so the tmux name on an ET record is diagnostics-only for now; capturing it
            // keeps ET consistent with Mosh if ET cold-reattach lands later.
            self.captureResume(host: host, transport: .et,
                               endpoint: (host: config.host, port: Int(config.port)),
                               secret: Data("\(serverCred.id)/\(serverCred.passkey)".utf8))
        }
        sess.onState = { raw in
            DebugLog.shared.log(.transport, "et: state=\(mapETState(Int32(raw)))")
        }
        sess.onEnd = { [weak self] reason in
            guard let self else { return }
            self.etWatchdog?.cancel(); self.etWatchdog = nil
            // User-initiated disconnect (the "x" button): `disconnect()` already tore the
            // session down and drove state to .idle. This async onEnd must NOT run the
            // failure path (teardown() reset etFirstFrameSeen, so etExitDecision would
            // wrongly return .handshakeFailed). Clean up silently and return.
            if self.etUserDisconnecting {
                DebugLog.shared.log(.transport, "et: onEnd during user disconnect → silent, no banner")
                self.etSession?.close()
                self.etSession = nil
                return
            }
            switch etExitDecision(reason: reason, sawFirstFrame: self.etFirstFrameSeen) {
            case .dismiss:
                // A real session ran (first-frame seen) and then ended (clean exit
                // or mid-session drop). Return to the connection list gracefully:
                // teardown() closes+nils etSession, cancels the watchdog, and resets
                // every flag; .idle dismisses the view. No error banner.
                DebugLog.shared.log(.transport, "et: session ended (first-frame seen) → dismiss to list")
                self.teardown()
                self.state = .idle
            case .handshakeFailed(let safe):
                // First-frame never fired: a pre-connect failure. If the watchdog
                // already resolved this session to a timeout .failed, a late onEnd
                // (enqueued before the callback was niled) must NOT clobber it.
                if self.etResolved {
                    DebugLog.shared.log(.transport, "et: onEnd after watchdog already resolved → ignored")
                    return
                }
                self.etResolved = true
                DebugLog.shared.log(.transport, "et: session ended pre-first-frame (\(safe)) → .failed")
                self.etSession?.close()   // release the retained ctx + tear down
                self.etSession = nil
                self.state = .failed(etFailureMessage(.handshakeFailed(reason: safe)))
            }
        }
        DebugLog.shared.log(.connect, "et: sess.start()")
        sess.start()
        etSession = sess
        connection = conn
        etWatchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)   // 15s
            guard !Task.isCancelled, let self, !self.etResolved else { return }
            self.etResolved = true
            DebugLog.shared.log(.transport, "et: watchdog fired (no first-frame/end in 15s) → .failed(timeout)")
            self.etSession?.close()
            self.etSession = nil
            self.state = .failed("Eternal Terminal timed out: no response on port 2022. Check that etserver is running and TCP 2022 is reachable (firewall).")
        }
        return .success(())
    }

    /// Whether a Mosh session is currently driving the terminal. The view uses
    /// this to route its debounced resize to `setMoshClientSize` (Mosh has no
    /// `ShellSession`, so `TerminalScreen`'s default `session?.resize` is a no-op).
    /// Keeps the `MoshSession` object itself private.
    var isMoshActive: Bool { moshSession != nil }

    /// Push a new terminal size to the running Mosh session. No-op outside Mosh mode.
    func setMoshClientSize(cols: Int, rows: Int) { moshSession?.resizeCols(Int32(cols), rows: Int32(rows)) }

    /// Whether an ET session is currently driving the terminal. The view uses this to
    /// route its debounced resize to `setETClientSize` (ET, like Mosh, has no
    /// `ShellSession`, so `TerminalScreen`'s default `session?.resize` is a no-op).
    var isETActive: Bool { etSession != nil }

    /// Route a debounced client-size change to the ET session. ET (like Mosh) has no
    /// `ShellSession`, so `TerminalScreen`'s default `session?.resize` is a no-op.
    func setETClientSize(cols: Int, rows: Int) {
        etSession?.setWindowSizeCols(UInt16(cols), rows: UInt16(rows), width: 0, height: 0)
    }

    /// Launch PLAIN tmux (driven per-host/default by `resolveUseTmux`)
    /// and feed its byte stream through the SAME raw single-terminal path
    /// `openRawShell` uses (`output`/`rawWriter`), so `TerminalScreen`/
    /// `RawTerminalContainer` need no structural change, only a gesture-callback
    /// wiring choice made at `makeUIView` time (see `TerminalScreen`). The
    /// `PlainTmuxController` itself is built lazily by `TerminalScreen.makeUIView`
    /// once the `TerminalView` mounts (`installPlainTmuxControllerIfNeeded`), which
    /// is only a mount signal now (no discovery, no view access); this method only
    /// launches the session and wires bytes.
    private func attachPlainTmux(conn: Connection) async throws {
        DebugLog.shared.log(.lifecycle, "attachPlainTmux: ENTER session=\(tmuxSessionNameForConnection)")
        guard isValidTmuxSessionName(tmuxSessionNameForConnection) else {
            DebugLog.shared.log(.lifecycle, "attachPlainTmux: invalid session name → degraded raw shell")
            degraded = .couldNotStart
            try await openRawShell(conn: conn)
            return
        }
        let startCmd = PlainTmuxController.launchCommand(sessionName: tmuxSessionNameForConnection)
        DebugLog.shared.log(.tmux, "attachPlainTmux: openExec startCmd=\(startCmd.prefix(60))")
        let sess = try await conn.openExec(command: startCmd, term: "xterm-256color",
                                           cols: 80, rows: 24, output: output)
        connection = conn
        session = sess
        rawWriter = SerialByteWriter(sink: ShellSessionSink(session: sess))
        plainTmuxSessionNamePendingInstall = tmuxSessionNameForConnection
        output.onHarvestBytes = { [weak self] bytes in
            self?.passwordDetector.noteOutput(bytes)
        }
        state = .shell
        DebugLog.shared.log(.lifecycle, "attachPlainTmux: exec opened, state=.shell, awaiting tmux output")
    }

    /// Set by `attachPlainTmux` to the launched session name, consumed once by
    /// `TerminalScreen.makeUIView` to construct `PlainTmuxController` against the
    /// freshly created `TerminalView` (nil = no plain-tmux install pending, either
    /// the gate is off or the controller is already installed).
    private(set) var plainTmuxSessionNamePendingInstall: String?

    /// The live raw `TerminalView`, stashed by `TerminalScreen.makeUIView` when it
    /// mounts. Lets a transport whose plain-tmux launch happens AFTER the view has
    /// mounted (Mosh/ET launch in-band on `onFirstFrame`, unlike SSH which sets the
    /// pending name synchronously before `state = .shell`) install the controller
    /// against the already-mounted view via `installPlainTmuxControllerIfMounted()`,
    /// rather than relying on a second `makeUIView` that never comes. Weak: the view
    /// is owned by SwiftUI; we only borrow it to build the controller.
    private weak var mountedTerminalView: TerminalView?

    /// Record the mounted raw `TerminalView` (called from `TerminalScreen.makeUIView`).
    func setMountedTerminalView(_ view: TerminalView) { mountedTerminalView = view }

    /// Install `PlainTmuxController` against the already-mounted `TerminalView`, if any.
    /// Used by the Mosh/ET `onFirstFrame` launch path, where the pending-install name is
    /// set AFTER `makeUIView` already ran its own (then-no-op) install. Idempotent via
    /// `installPlainTmuxControllerIfNeeded`'s `plainTmux == nil` guard; a no-op when the
    /// view hasn't mounted yet (then `makeUIView` will install once it does).
    func installPlainTmuxControllerIfMounted() {
        guard let view = mountedTerminalView else { return }
        installPlainTmuxControllerIfNeeded(screen: view)
    }

    /// Build and retain `PlainTmuxController` once the raw `TerminalView` has mounted,
    /// consuming `plainTmuxSessionNamePendingInstall`. Idempotent: a second call (e.g. a
    /// SwiftUI `makeUIView` re-invocation) is a no-op once `plainTmux` is set. `screen` is
    /// only the mount signal; the controller needs no view access.
    func installPlainTmuxControllerIfNeeded(screen: TerminalView) {
        guard plainTmux == nil, let name = plainTmuxSessionNamePendingInstall else { return }
        plainTmuxSessionNamePendingInstall = nil
        plainTmux = PlainTmuxController(
            sessionName: name,
            // Route gesture bytes through the transport-aware send, NOT `rawWriter`
            // directly: `rawWriter` is only set on the SSH paths, so on Mosh/ET it is nil
            // and gestures would be silently dropped (device bug 2026-09-06).
            sendInput: { [weak self] bytes in self?.sendTerminalInput(bytes) })
        DebugLog.shared.log(.tmux, "plainTmux: controller installed session=\(name)")
    }

    /// Reactive tmux-missing detector for Mosh/ET (see `attachMoshIfPossible`/
    /// `attachET`): those transports attach a login shell with no pre-frame exec
    /// channel, so tmux viability can only be checked by watching the first
    /// output after the in-band plain-tmux launch (attach-or-create). Classifies the
    /// accumulated `plainTmuxProbeBuffer` via the pure Kit detector
    /// (`classifyTmuxLaunch`) and resolves at most once per session.
    /// `.tmuxMissing` tears down the gesture layer only, the raw shell underneath
    /// is already live (fed by the same `output.onOutput` this buffer reads from),
    /// so no separate raw-shell attach is needed here.
    private func evaluatePlainTmuxProbe() {
        guard !plainTmuxProbeResolved else { return }
        switch classifyTmuxLaunch(output: plainTmuxProbeBuffer) {
        case .tmuxMissing:
            plainTmuxProbeResolved = true
            plainTmuxProbeWatchdog?.cancel(); plainTmuxProbeWatchdog = nil
            DebugLog.shared.log(.tmux, "plainTmux probe: tmuxMissing → degrade to raw shell, drop gesture layer")
            degraded = .tmuxNotFound
            connectOverlayTmuxMissing = true   // this launch's verdict (see the overlay)
            plainTmuxSessionNamePendingInstall = nil
            plainTmux = nil
        case .tmuxStarted:
            plainTmuxProbeResolved = true
            plainTmuxProbeWatchdog?.cancel(); plainTmuxProbeWatchdog = nil
            DebugLog.shared.log(.tmux, "plainTmux probe: tmuxStarted → keep gesture layer")
        case .inconclusive:
            break   // keep accumulating until the watchdog window expires
        }
    }

    // MARK: - Connecting overlay

    /// Raise the "Connecting to <host>..." overlay at the in-band plain-tmux launch
    /// (call right before the launch is written). Resets the reveal inputs, stamps the
    /// launch time and arms the `connectRevealTimeoutSeconds` backstop.
    private func beginConnectOverlay() {
        connectOverlayTimeout?.cancel()
        connectOverlayQuietCheck?.cancel(); connectOverlayQuietCheck = nil
        connectOverlayLaunchedAt = ProcessInfo.processInfo.systemUptime
        connectOverlaySentinelSeen = false
        connectOverlayLastOutputAt = nil
        connectOverlayMouseOn = false
        connectOverlayTmuxMissing = false
        connectOverlay = true
        DebugLog.shared.log(.connect, "connect:overlay up (in-band tmux launch)")
        connectOverlayTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(connectRevealTimeoutSeconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            // The backstop must fire even if uptime reads a hair under the deadline
            // (clock granularity, device sleep): force the timeout reveal.
            self.evaluateConnectReveal(deadlineReached: true)
        }
    }

    /// Feed one output chunk to the overlay (Mosh/ET `onOutput`, after the probe buffer
    /// was updated). The chunk that first carries the sentinel only marks it seen; every
    /// LATER chunk is post-sentinel output that restarts the quiet window.
    private func noteConnectOverlayOutput() {
        guard connectOverlay else { return }
        if !connectOverlaySentinelSeen {
            connectOverlaySentinelSeen = containsPlainTmuxLaunchSentinel(plainTmuxProbeBuffer)
        } else {
            connectOverlayLastOutputAt = ProcessInfo.processInfo.systemUptime
            connectOverlayQuietCheck?.cancel()
            connectOverlayQuietCheck = Task { [weak self] in
                // A hair past the window so the re-check lands on the reveal side of it.
                try? await Task.sleep(nanoseconds: UInt64((connectRevealQuietSeconds + 0.01) * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                self.evaluateConnectReveal()
            }
        }
        evaluateConnectReveal()
    }

    /// The mounted terminal's mouse reporting changed (`TerminalScreen`'s mode hook). Only
    /// meaningful while the overlay is up: tmux turning mouse mode on means it attached.
    func noteTerminalMouseMode(on: Bool) {
        guard connectOverlay else { return }
        connectOverlayMouseOn = on
        evaluateConnectReveal()
    }

    /// Ask the pure `connectRevealDecision` whether to lower the overlay; on a reveal,
    /// lower it, cancel its timers and log the decision line once. `sessionEnded` is
    /// passed by the end paths (teardown, `.idle`/`.failed`, crash banner).
    /// `deadlineReached` is passed only by the timeout Task: when the decider would keep
    /// covering, it reveals with `.timeout` anyway. No-op while the overlay is down.
    private func evaluateConnectReveal(sessionEnded: Bool = false, deadlineReached: Bool = false) {
        guard connectOverlay else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let input = ConnectRevealInput(
            sentinelSeen: connectOverlaySentinelSeen,
            secondsSinceLastOutput: connectOverlayLastOutputAt.map { now - $0 },
            mouseModeOn: connectOverlayMouseOn,
            tmuxMissing: connectOverlayTmuxMissing,
            sessionEnded: sessionEnded,
            secondsSinceLaunch: now - connectOverlayLaunchedAt)
        guard let reason = connectRevealDecision(input) ?? (deadlineReached ? ConnectRevealReason.timeout : nil) else { return }
        connectOverlay = false
        connectOverlayTimeout?.cancel(); connectOverlayTimeout = nil
        connectOverlayQuietCheck?.cancel(); connectOverlayQuietCheck = nil
        DebugLog.shared.log(.connect, connectRevealLogLine(input, reason: reason))
    }

    // MARK: - Banner actions

    /// Banner action, stay in degraded raw-shell mode for the rest of the session.
    func dismissCrashBanner() { crashBanner = nil }

    // MARK: - Predictor

    /// Persist the session's learned predictor vocabulary to disk. Idempotent and
    /// safe to call repeatedly; a no-op when the predictor is disabled (incognito)
    /// or no learned store is attached. Called from `teardown()` and on
    /// app-background (`scenePhase`) so learning survives a backgrounded or killed
    /// app, previously only a clean teardown flushed. The snapshot+save now runs on
    /// a detached `Task` (the engine lives behind `PredictorActor`); the actor
    /// reference is captured before any subsequent `predictor = nil`, so the flush
    /// completes against the correct engine even as teardown proceeds.
    func flushPredictor() {
        guard let predictor, let learnedStore else { return }
        Task { let s = await predictor.snapshotState(); try? learnedStore.save(s) }
    }

    /// On app-background, suspend the live mosh session (Ctrl-^ Ctrl-Z), capture the
    /// serialized transport-state blob, and persist it so a reopen can re-home to the
    /// still-alive server at the correct sequence. Wrapped in a background task so
    /// iOS's ~5s suspension budget can't cut the capture/write short.
    func suspendMoshForBackground() {
        guard let sess = moshSession else { return }
        let sid = sessionID
        var bgTask: UIBackgroundTaskIdentifier = .invalid
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "mosh-suspend") {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
        // The blob capture must NOT depend on `moshSession` staying non-nil: this
        // block captures `sid` (not `self.moshSession`) and calls the store directly,
        // so niling moshSession below is safe for the persist.
        sess.onEncodedState = { blob in
            do {
                try AppStores.shared.moshState.put(blob, sessionID: sid)
                DebugLog.shared.log(.connect, "mosh:suspend captured+persisted blob=\(blob.count)B sid=\(sid)")
            } catch {
                DebugLog.shared.log(.connect, "mosh:suspend persist FAILED error=\(error)")
            }
            if bgTask != .invalid {
                UIApplication.shared.endBackgroundTask(bgTask)
                bgTask = .invalid
            }
        }
        // suspendForResume sends Ctrl-^ Ctrl-Z, and mosh SUSPEND makes the vendored
        // client pthread_exit SYNCHRONOUSLY inside mosh_main, so runMoshLoop's own
        // teardown (fclose + fireEnd) NEVER runs. suspendForResume therefore drives
        // the session's teardown itself (via -stop, which nils onEnd), so onEnd will
        // NOT fire here to flip us off `.shell`. We must do the VM-side transition
        // ourselves, or warm-foreground's `guard state == .idle` in
        // resumeMoshOnForegroundIfNeeded() fails and no re-home happens (frozen
        // terminal on reopen, the feature's primary case).
        sess.suspendForResume()
        DebugLog.shared.log(.connect, "mosh:suspend sent Ctrl-^ Ctrl-Z sid=\(sid)")
        // Cancel any in-flight mosh watchdogs/probes for this now-suspended session so
        // they can't fire against the torn-down session (mirrors teardown()'s subset).
        moshWatchdog?.cancel(); moshWatchdog = nil
        moshReattachWatchdog?.cancel(); moshReattachWatchdog = nil
        moshReattachSawServerOutput = false
        moshResolved = false
        plainTmuxProbeWatchdog?.cancel(); plainTmuxProbeWatchdog = nil
        // Drop the live session handle + leave `.shell`. onEncodedState above (already
        // captured `sid`) still fires on the main queue independently of this, so the
        // blob is persisted regardless of niling moshSession. On `.active`,
        // resumeMoshOnForegroundIfNeeded() now finds `state == .idle` and re-homes.
        // Set moshSuspendedForResume BEFORE flipping to `.idle` so SessionView's
        // `.onChange(state)` sees it and suppresses the dismiss-on-idle (otherwise the
        // cover drops to the host list and the in-place foreground re-home never runs).
        moshSuspendedForResume = true
        moshSession = nil
        state = .idle
        DebugLog.shared.log(.connect, "mosh:suspend torn down → .idle (warm-foreground will re-home)")
    }

    /// Forget the most-recently-typed line's un-graduated tokens (surgical L7 tool).
    /// Surfaced by the predictor strip's eraser. No-op when the predictor is off.
    func forgetLastLine() {
        DebugLog.shared.log(.predictor, "predictor:forgetLastLine")
        Task { [predictor] in await predictor?.forgetLastLine() }
        // Ephemeral drop, nothing to persist; suggestions refresh on next input.
    }

    /// `PredictorPurgeable`: reset the running engine to empty (seed preserved).
    /// Called by `AppStores.purgePredictorLearned()` when THIS session is the active
    /// one, so a panic-purge triggered from Settings, even mid-session, clears the
    /// in-memory learned state before the on-disk store is deleted. No-op when the
    /// predictor is off (incognito).
    func purgeLearnedEngine() {
        DebugLog.shared.log(.predictor, "predictor:purge")
        Task { [predictor] in await predictor?.purgeLearned() }
    }

    /// Panic-purge: wipe all user-derived predictor state now (live engine + disk).
    /// Delegates to the store, which resets this session's engine (via the
    /// `activePredictorSession` registration) before deleting the file, so there is
    /// no stale-write-back window.
    ///
    /// Reserved as an in-session call site (e.g. a session-UI purge button); today
    /// `PrivacySettingsView` drives the purge through `AppStores` directly and the
    /// registration handles the live engine, so this convenience wrapper has no
    /// caller yet.
    func panicPurge() {
        try? AppStores.shared.purgePredictorLearned()
    }

    /// Build the session predictor unless incognito is on for this host.
    private func startPredictor(host: Host, defaults: Defaults) {
        guard !resolvePredictorIncognito(host: host, defaults: defaults) else {
            predictor = nil
            // Incognito: no engine to reset, so don't claim the active-purge slot.
            if AppStores.shared.activePredictorSession === self {
                AppStores.shared.activePredictorSession = nil
            }
            return
        }
        let store = AppStores.shared.predictorLearnedStore()
        learnedStore = store
        predictor = PredictorActor(engine: PredictorEngine(
            learned: store.load(),
            seed: AppStores.shared.predictorSeed(),
            proseSeed: AppStores.shared.proseSeed(),
            filter: AppStores.shared.predictorTokenFilter()))
        // Register as the session a Settings-triggered panic-purge should reset.
        AppStores.shared.activePredictorSession = self
    }

    /// Fold outgoing bytes into the token tracker, learn committed tokens (unless
    /// the line is a password entry), and refresh the suggestion chips.
    ///
    /// Learning is gated by `passwordDetector`: tokens committed on a line are
    /// buffered and only recorded once the line commits (Enter) AND the detector
    /// confirms the line was echoed and not preceded by a password prompt. A
    /// space-committed token mid-line is held until its line's verdict is known,
    /// so a multi-word line is learned or dropped as a unit. This keeps typed
    /// passwords (sudo / ssh / passphrase prompts) out of the synced vocabulary;
    /// the token filter alone can't catch a short low-entropy password.
    private func observePredictorInput(_ bytes: [UInt8]) {
        guard predictor != nil else { return }
        // L1: snapshot the pre-delivery cursor as THIS call's echo anchor, then
        // after a bounded window classify this call's keystrokes against the grid.
        // The anchor is captured per-call (not shared state), so concurrent
        // per-keystroke settles never clobber each other.
        let scalars = predictorScalars(bytes)
        let anchor = scalars.isEmpty ? nil : passwordDetector.currentCursor()
        passwordDetector.noteInput(bytes)
        for committed in tracker.observe(bytes) {
            pendingLineTokens.append(committed)
        }
        // Secret-exclusion drop-gate trace (audit 2026-07-19: these gates were previously
        // invisible). Log ONLY when this chunk actually dropped something, and the DELTA
        // (tallies are monotonic until reset). PRIVACY: counts only, never token text.
        let dPaste = tracker.droppedInPaste - lastDropInPaste
        let dSecret = tracker.droppedAsSecret - lastDropAsSecret
        if dPaste > 0 || dSecret > 0 {
            lastDropInPaste = tracker.droppedInPaste
            lastDropAsSecret = tracker.droppedAsSecret
            DebugLog.shared.log(.predictor, decisionLine(
                "predictor:drop-gate",
                inputs: [("bytes", "\(bytes.count)")],
                outputs: [("paste", "\(dPaste)"), ("secret", "\(dSecret)")],
                reason: dSecret > 0 ? "L4b-secret" : "L3-paste"))
        }
        // If this chunk left the line empty with no usable preceding token (an ESC /
        // Ctrl-* / control line reset, or a backspace-to-empty), clear stale chips now.
        // Enter is already handled synchronously below; the normal typing case has a
        // non-empty `current` so this is a no-op there. (predictor-suggestion-hygiene
        // spec, Fix 4: "clear on ESC/control line reset".)
        if tracker.current.isEmpty, tracker.previous?.isEmpty != false {
            predictorVM.setSuggestions([])
        }
        // L4a: the tracker latches the just-committed line's opt-out at its Enter,
        // so this is correct even when a leading-space line and its Enter arrive in
        // ONE chunk (paste). (Per-chunk coarseness matches L1's: a chunk with two
        // full lines of mixed opt-out applies the last line's verdict, a known v1
        // limit, not a realistic paste-a-secret case.)
        let optedOut = tracker.lastCommittedLineOptedOut
        let deadline = DispatchTime.now() + .milliseconds(40)
        // `observePredictorInput` and the coalescer are both @MainActor (this VM is
        // @MainActor; the only caller is `sendTerminalInput`), so no lock is needed.
        // Settle and refresh run in the same hop in program order: no fragile
        // wall-clock offsets between them (findings C/D).
        if !scalars.isEmpty || containsEditingKey(bytes) {
            refreshCoalescer.requestRefresh(at: Date().timeIntervalSinceReferenceDate)
            DispatchQueue.main.asyncAfter(deadline: deadline) { [weak self] in
                guard let self else { return }
                // 1) settle echo against the grid (L1), THEN
                self.passwordDetector.settleLine(scalars: scalars, from: anchor)
                // 2) recompute suggestions in the same main-actor hop, in program order,
                //    so the refresh always reflects post-settle state (findings C/D, no
                //    fragile inter-hop wall-clock offsets). Trailing-debounce preserved:
                //    only recompute if no newer keystroke arrived.
                if self.refreshCoalescer.isDue(at: Date().timeIntervalSinceReferenceDate) {
                    self.refreshPredictorSuggestions()
                }
            }
        }
        for b in bytes where b == 0x0d || b == 0x0a {
            predictorVM.setSuggestions([])   // line committed → clear stale chips immediately
            // This closure runs on the main queue and touches @MainActor state (passwordDetector,
            // pendingLineTokens) and the @MainActor DebugLog directly, legal via the closure's
            // inferred main-actor isolation. If ever extracted to a @Sendable/non-capturing form,
            // the DebugLog + self accesses need an explicit MainActor.assumeIsolated/await.
            DispatchQueue.main.asyncAfter(deadline: deadline + .milliseconds(10)) { [weak self] in
                guard let self else { return }
                let echoConfirmed = self.passwordDetector.shouldLearnCommittedLine()
                // Learn only if L1 confirms echo AND the line was not opted out (L4a); the
                // engine still folds echo/opt-out/L5 into the L7 confidence tier.
                if !optedOut, echoConfirmed {
                    let toLearn = self.pendingLineTokens
                    DebugLog.shared.log(.predictor,
                        "predictor:record tokens=\(toLearn.count) echo=\(echoConfirmed) optedOut=\(optedOut)")
                    Task { [predictor = self.predictor] in
                        await predictor?.beginLine()
                        await predictor?.record(toLearn, echoConfirmed: echoConfirmed, optedOut: optedOut)
                    }
                } else {
                    DebugLog.shared.log(.predictor,
                        "predictor:recordSuppressed echo=\(echoConfirmed) optedOut=\(optedOut)")
                }
                self.pendingLineTokens.removeAll(keepingCapacity: true)
                self.passwordDetector.resetLine()
            }
        }
    }

    private func refreshPredictorSuggestions() {
        guard let predictor else { predictorVM.setSuggestions([]); return }
        let prefix = tracker.current, prev = tracker.previous

        // Build the prediction context from signals the VM already holds. Any signal
        // that is not cheaply available stays nil (the bias treats nil as abstain).
        // No foreground-process signal on the plain tmux / raw paths (the per-pane
        // process poll went with -CC), so the process abstains.
        let process: String? = nil
        let isAlt = activePaneView()?.getTerminal().isCurrentBufferAlternate
        let ctx = PredictionContext(foregroundProcess: process,
                                    isAlternateScreen: isAlt,
                                    line: tracker.line,
                                    cursorIndex: tracker.cursorIndex)

        let optedOut = tracker.lineOptedOut
        let precedingToken = prev   // the token immediately before `current` on this line

        predictorRefreshSeq += 1
        let seq = predictorRefreshSeq
        Task { [weak self] in
            guard let self else { return }
            let minPrefix = await predictor.minPrefix()
            let request = suggestionRequest(
                current: prefix, previous: prev, precedingToken: precedingToken,
                lineOptedOut: optedOut, minPrefix: minPrefix)
            var chips: [(text: String, kind: SuggestionKind)] = []
            switch request {
            case .blended(let current, let previous, let allowNextWord):
                let blended = await predictor.blendedSuggestions(
                    current: current, previous: previous, allowNextWord: allowNextWord, context: ctx)
                chips = blended.map { ($0.token, $0.isNextWord ? .nextWordAfterCurrent : .completeWord) }
            case .nextWord(let word):
                let raw = await predictor.suggestions(forPrefix: "", after: word, context: ctx)
                chips = predictorChips(current: word, suggestions: raw).map { ($0, .nextWordAfterPrevious) }
            case .none:
                chips = []
            }
            await MainActor.run {
                DebugLog.shared.log(.predictor,
                    "predictor:suggest seq=\(seq) prefix='\(prefix)' proc=\(process ?? "nil") alt=\(isAlt.map(String.init) ?? "nil") count=\(chips.count)")
                self.predictorVM.setChips(chips, seq: seq)
            }
        }
    }

    /// Accept a chip. completeWord chips extend the current token (send the suffix);
    /// next-word chips insert a fresh word (+ spacing) so the user can keep chaining. The
    /// inserted bytes flow back through `sendTerminalInput`, so tracker + suggestions update.
    func acceptSuggestion(_ s: String) {
        let kind = predictorVM.kindByToken[s] ?? .completeWord
        guard let insertion = acceptanceInsertion(kind: kind, current: tracker.current, chip: s) else { return }
        predictorVM.setSuggestions([])   // clear immediately; the echo round-trip repopulates
        sendTerminalInput(Array(insertion.utf8))
    }

    // MARK: - Connect (saved host)

    /// Connect from a saved `Host` record, using its resolved config and a
    /// caller-supplied password. Does NOT create or modify any host record
    /// (contrast with `connect(host:port:user:password:)` which calls
    /// `findOrCreateHost`). Throws a user-facing `.failed` state if the user
    /// field cannot be resolved.
    func connect(savedHost: Host, password: String) {
        if state == .connecting || state == .shell {
            DebugLog.shared.log(.connect, "connect(saved): IGNORED, already \(state == .connecting ? "connecting" : "in shell")")
            return
        }
        lastSavedHost = savedHost
        lastPassword = password
        teardown()
        sessionID = UUID()   // fresh resume key for this connection (teardown cleared the old)
        etUserDisconnecting = false   // fresh connection: clear any prior user-disconnect guard
        state = .connecting
        degraded = nil
        let defaults = (try? AppStores.shared.hosts.defaults()) ?? Defaults()
        let user: String
        do {
            user = try resolveUser(host: savedHost, defaults: defaults)
        } catch ResolutionError.userUnset {
            DebugLog.shared.log(.connect, "connect(saved): user unset → .failed (pre-connect)")
            state = .failed("Set a user for this host or in Defaults to connect.")
            return
        } catch {
            DebugLog.shared.log(.connect, "connect(saved): resolveUser THREW \(String(describing: error)) → .failed")
            state = .failed(String(describing: error))
            return
        }
        let port = resolvePort(host: savedHost, defaults: defaults)
        let addr = "\(savedHost.hostName):\(port)"
        output.onExit = { [weak self] exit in
            DebugLog.shared.log(.connect, "connect(saved): output.onExit → .failed(\(exit.error ?? "Session closed"))")
            self?.clearResume()   // raw/session exit is an observable end: clear the record
            self?.state = .failed(exit.error ?? "Session closed")
        }
        DebugLog.shared.log(.connect, "connect(saved): START addr=\(addr) user=\(user)")
        Task {
            do {
                let verifier = TofuHostKeyVerifier(
                    hostID: savedHost.id, trust: AppStores.shared.trust,
                    present: { [weak self] prompt in await self?.present(prompt) ?? false })
                let conn = try await SemicolynSSHCoreFFI.connect(
                    addr: addr, allowLegacy: false, allowDeprecated: false,
                    keepalive: keepaliveConfig(host: savedHost, defaults: defaults),
                    verifier: verifier)
                DebugLog.shared.log(.connect, "connect(saved): TCP+handshake OK, authenticating")
                let outcome = try await authenticate(conn: conn, user: user, host: savedHost, defaults: defaults, password: password)
                switch outcome {
                case .success:
                    DebugLog.shared.log(.connect, "connect(saved): auth SUCCESS")
                default:
                    DebugLog.shared.log(.connect, "connect(saved): auth FAILED (\(String(describing: outcome))) → .failed")
                    state = .failed("Authentication failed")
                    return
                }
                // Probe + branch on tmux availability.
                let defaults2 = (try? AppStores.shared.hosts.defaults()) ?? Defaults()
                osc52Allowed = resolveOsc52Allow(host: savedHost, defaults: defaults2)
                // resolveOsc52Allow reads the leaf-independent `semicolyn.osc52.allow`
                // (host container's leaf, else Defaults container's leaf, else true).
                // Log both containers' explicit-vs-inherit state alongside the result.
                let hostSemicolynExplicit: Bool
                if case .explicit = savedHost.semicolyn { hostSemicolynExplicit = true } else { hostSemicolynExplicit = false }
                let defaultsSemicolynExplicit: Bool
                if case .explicit = defaults2.semicolyn { defaultsSemicolynExplicit = true } else { defaultsSemicolynExplicit = false }
                DebugLog.shared.log(.connect, decisionLine(
                    "connect:osc52",
                    inputs: [("hostSemicolynExplicit", "\(hostSemicolynExplicit)"),
                             ("defaultsSemicolynExplicit", "\(defaultsSemicolynExplicit)")],
                    outputs: [("osc52Allowed", "\(osc52Allowed)")],
                    reason: nil))
                startPredictor(host: savedHost, defaults: defaults2)
                switch resolveTransport(host: savedHost, defaults: defaults2) {
                case .et:
                    switch await attachET(conn: conn, host: savedHost, defaults: defaults2) {
                    case .success:
                        DebugLog.shared.log(.connect, "connect(saved): went ET path")
                        return
                    case .failure(let e):
                        DebugLog.shared.log(.connect, "connect(saved): ET FAILED (\(e))")
                        state = .failed(etFailureMessage(e))
                        return
                    }
                case .mosh:
                    if await attachMoshIfPossible(conn: conn, host: savedHost, defaults: defaults2) {
                        DebugLog.shared.log(.connect, "connect(saved): went MOSH path")
                        return
                    }
                    DebugLog.shared.log(.connect, "connect(saved): MOSH explicit but bootstrap failed → .failed")
                    state = .failed("Mosh could not connect to this host.")
                    return
                case .ssh:
                    DebugLog.shared.log(.lifecycle, "connect(saved): → attachSSHShell (tmux/raw)")
                    try await attachSSHShell(conn: conn, host: savedHost, defaults: defaults2)
                }
            } catch ConnectError.HostKeyRejected {
                DebugLog.shared.log(.connect, "connect(saved): HostKeyRejected → .failed")
                state = .failed("Host key not trusted")
            } catch ConnectError.Timeout {
                DebugLog.shared.log(.connect, "connect(saved): Timeout → .failed")
                state = .failed("Couldn't reach host, connection timed out")
            } catch {
                DebugLog.shared.log(.connect, "connect(saved): THREW \(String(describing: error)) → .failed")
                state = .failed(String(describing: error))
            }
        }
    }

    // MARK: - Connect (ad-hoc)

    func connect(host: String, port: String, user: String, password: String) {
        if state == .connecting || state == .shell {
            DebugLog.shared.log(.connect, "connect(adhoc): IGNORED, already \(state == .connecting ? "connecting" : "in shell")")
            return
        }
        teardown()
        sessionID = UUID()   // fresh resume key for this connection (teardown cleared the old)
        etUserDisconnecting = false   // fresh connection: clear any prior user-disconnect guard
        state = .connecting
        degraded = nil
        let addr = "\(host):\(port.isEmpty ? "22" : port)"
        output.onExit = { [weak self] exit in
            DebugLog.shared.log(.connect, "connect(adhoc): output.onExit → .failed(\(exit.error ?? "Session closed"))")
            self?.clearResume()   // raw/session exit is an observable end: clear the record
            self?.state = .failed(exit.error ?? "Session closed")
        }
        DebugLog.shared.log(.connect, "connect(adhoc): START addr=\(addr) user=\(user)")
        Task {
            do {
                let portNum = Int(port) ?? 22
                let hostRecord = try findOrCreateHost(hostName: host, port: portNum, user: user)
                let defaults = (try? AppStores.shared.hosts.defaults()) ?? Defaults()
                let verifier = TofuHostKeyVerifier(
                    hostID: hostRecord.id, trust: AppStores.shared.trust,
                    present: { [weak self] prompt in await self?.present(prompt) ?? false })
                let conn = try await SemicolynSSHCoreFFI.connect(
                    addr: addr, allowLegacy: false, allowDeprecated: false,
                    keepalive: keepaliveConfig(host: hostRecord, defaults: defaults),
                    verifier: verifier)
                DebugLog.shared.log(.connect, "connect(adhoc): TCP+handshake OK, authenticating")
                let outcome = try await authenticate(conn: conn, user: user, host: hostRecord, defaults: defaults, password: password)
                switch outcome {
                case .success:
                    DebugLog.shared.log(.connect, "connect(adhoc): auth SUCCESS")
                default:
                    DebugLog.shared.log(.connect, "connect(adhoc): auth FAILED (\(String(describing: outcome))) → .failed")
                    state = .failed("Authentication failed")
                    return
                }
                // Probe + branch on tmux availability.
                let defaults2 = (try? AppStores.shared.hosts.defaults()) ?? Defaults()
                osc52Allowed = resolveOsc52Allow(host: hostRecord, defaults: defaults2)
                // resolveOsc52Allow reads the leaf-independent `semicolyn.osc52.allow`
                // (host container's leaf, else Defaults container's leaf, else true).
                // Log both containers' explicit-vs-inherit state alongside the result.
                let hostSemicolynExplicit: Bool
                if case .explicit = hostRecord.semicolyn { hostSemicolynExplicit = true } else { hostSemicolynExplicit = false }
                let defaultsSemicolynExplicit: Bool
                if case .explicit = defaults2.semicolyn { defaultsSemicolynExplicit = true } else { defaultsSemicolynExplicit = false }
                DebugLog.shared.log(.connect, decisionLine(
                    "connect:osc52",
                    inputs: [("hostSemicolynExplicit", "\(hostSemicolynExplicit)"),
                             ("defaultsSemicolynExplicit", "\(defaultsSemicolynExplicit)")],
                    outputs: [("osc52Allowed", "\(osc52Allowed)")],
                    reason: nil))
                startPredictor(host: hostRecord, defaults: defaults2)
                switch resolveTransport(host: hostRecord, defaults: defaults2) {
                case .et:
                    switch await attachET(conn: conn, host: hostRecord, defaults: defaults2) {
                    case .success:
                        DebugLog.shared.log(.connect, "connect(adhoc): went ET path")
                        return
                    case .failure(let e):
                        DebugLog.shared.log(.connect, "connect(adhoc): ET FAILED (\(e))")
                        state = .failed(etFailureMessage(e))
                        return
                    }
                case .mosh:
                    if await attachMoshIfPossible(conn: conn, host: hostRecord, defaults: defaults2) {
                        DebugLog.shared.log(.connect, "connect(adhoc): went MOSH path")
                        return
                    }
                    DebugLog.shared.log(.connect, "connect(adhoc): MOSH explicit but bootstrap failed → .failed")
                    state = .failed("Mosh could not connect to this host.")
                    return
                case .ssh:
                    DebugLog.shared.log(.lifecycle, "connect(adhoc): → attachSSHShell (tmux/raw)")
                    try await attachSSHShell(conn: conn, host: hostRecord, defaults: defaults2)
                }
            } catch ConnectError.HostKeyRejected {
                DebugLog.shared.log(.connect, "connect(adhoc): HostKeyRejected → .failed")
                state = .failed("Host key not trusted")
            } catch ConnectError.Timeout {
                DebugLog.shared.log(.connect, "connect(adhoc): Timeout → .failed")
                state = .failed("Couldn't reach host, connection timed out")
            } catch {
                DebugLog.shared.log(.connect, "connect(adhoc): THREW \(String(describing: error)) → .failed")
                state = .failed(String(describing: error))
            }
        }
    }

    /// Resolves the host's keepalive policy (OpenSSH `ServerAliveInterval` /
    /// `ServerAliveCountMax`) into the Rust core's `KeepaliveConfig`, so an idle
    /// interactive session stays alive. `interval == 0` disables keepalives
    /// (the resolve fallbacks are 30 / 3).
    private func keepaliveConfig(host: Host, defaults: Defaults) -> KeepaliveConfig {
        KeepaliveConfig(
            intervalSecs: UInt32(max(0, resolveServerAliveInterval(host: host, defaults: defaults))),
            countMax: UInt32(max(0, resolveServerAliveCountMax(host: host, defaults: defaults))))
    }
}
