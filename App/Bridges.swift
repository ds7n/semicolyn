// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import SemicolynKit
import SemicolynSSHCoreFFI

/// Bridges the Rust host-key trust callback to the TOFU evaluator + the SwiftUI
/// first-trust / mismatch modals. `present` shows the modal on the main actor and
/// returns the user's trust decision; storage is written only after an accept.
final class TofuHostKeyVerifier: HostKeyVerifier {
    private let hostID: UUID
    private let trust: HostKeyTrustEvaluator
    private let present: @MainActor (HostKeyPrompt) async -> Bool
    private let notify: @MainActor (String) -> Void

    /// `notify` shows a non-blocking notice (used when an accepted key couldn't be saved).
    init(hostID: UUID, trust: HostKeyTrustEvaluator,
         present: @escaping @MainActor (HostKeyPrompt) async -> Bool,
         notify: @escaping @MainActor (String) -> Void) {
        self.hostID = hostID; self.trust = trust; self.present = present; self.notify = notify
    }

    /// Shown when the user accepted a host key but it couldn't be saved.
    static let saveFailureMessage =
        "Couldn't save this server's key. You'll be asked to confirm it again next time."

    /// Saves an accepted key (security audit L4: a failed write is logged and shown, not
    /// swallowed). The connection still goes ahead: the user approved this key, and an
    /// unsaved key only means the same prompt appears on the next connect.
    private func save(_ write: () throws -> Void) async {
        do {
            try write()
        } catch {
            await DebugLog.shared.log(.connect, "hostkey: saving accepted key FAILED (\(error)) → notice, prompt again next connect")
            await notify(Self.saveFailureMessage)
        }
    }

    /// Shown when the stored host keys couldn't be read and the connection was refused.
    static let storeFailureMessage =
        "Couldn't read the saved host keys for this server, so semicolyn didn't connect. Try again."

    private let failureLock = NSLock()
    private var storeFailed = false

    /// `true` once `verify` refused a connection because the stored host keys couldn't be
    /// read (security audit M2: a storage fault must not hide a mismatch).
    var refusedForStoreFailure: Bool { failureLock.withLock { storeFailed } }

    func verify(info: HostKeyInfo) async -> Bool {
        // DebugLog is @MainActor; verify() is non-isolated async, so these hops need
        // `await`. Fine here, host-key verify runs once per connect, not on any hot
        // path, so the main-actor hop cost is irrelevant.
        let decision: HostKeyDecision
        do {
            decision = try trust.evaluate(hostID: hostID, algorithm: info.keyType,
                                          fingerprint: info.fingerprint)
        } catch {
            // Fail closed: treating an unreadable store as "never seen" would show the
            // first-connect prompt for a server whose key may have changed.
            failureLock.withLock { storeFailed = true }
            await DebugLog.shared.log(.connect, "hostkey: trust.evaluate THREW (\(error)) → REJECT (fail closed)")
            return false
        }
        switch decision {
        case .trusted:
            await DebugLog.shared.log(.connect, "hostkey: TRUSTED (\(info.keyType)) → accept, no prompt")
            return true
        case .firstTrust:
            await DebugLog.shared.log(.connect, "hostkey: firstTrust (\(info.keyType)) → prompting user")
            let ok = await present(.firstTrust(hostLabel: info.hostLabel, keyType: info.keyType,
                                               offered: info.fingerprint))
            await DebugLog.shared.log(.connect, "hostkey: firstTrust → user \(ok ? "ACCEPTED (storing trust)" : "REJECTED")")
            if ok {
                await save { try trust.trust(hostID: hostID, algorithm: info.keyType,
                                             fingerprint: info.fingerprint, at: Date()) }
            }
            return ok
        case .newKeyType(let known):
            // Security audit H3: a known host switching key type is warned, not treated as new.
            let knownTypes = Array(Set(known.map(\.algorithm))).sorted()
            await DebugLog.shared.log(.connect, "hostkey: NEW KEY TYPE (\(info.keyType)), known=\(knownTypes) → prompting user")
            let ok = await present(.newKeyType(hostLabel: info.hostLabel, keyType: info.keyType,
                                               offered: info.fingerprint, knownTypes: knownTypes))
            await DebugLog.shared.log(.connect, "hostkey: newKeyType → user \(ok ? "ACCEPTED (storing trust)" : "REJECTED")")
            if ok {
                await save { try trust.trust(hostID: hostID, algorithm: info.keyType,
                                             fingerprint: info.fingerprint, at: Date()) }
            }
            return ok
        case .mismatch(let stored):
            await DebugLog.shared.log(.connect, "hostkey: MISMATCH (\(info.keyType)), stored key differs → prompting user")
            let ok = await present(.mismatch(hostLabel: info.hostLabel, keyType: info.keyType,
                                             stored: stored.first?.fingerprint ?? "",
                                             offered: info.fingerprint))
            await DebugLog.shared.log(.connect, "hostkey: mismatch → user \(ok ? "ACCEPTED (replacing trust)" : "REJECTED")")
            if ok {
                await save { try trust.replace(hostID: hostID, algorithm: info.keyType,
                                               fingerprint: info.fingerprint, at: Date()) }
            }
            return ok
        }
    }
}

/// Receives merged stdout/stderr from the Rust PTY pump and forwards it to the
/// UI. The Rust side invokes these callbacks off the main thread, so every
/// hand-off hops to main before touching UIKit/SwiftTerm. Decoupled from the
/// terminal view via closures so this stays SwiftTerm-free.
final class TerminalShellOutput: ShellOutput {
    /// Render slot, set by the terminal view (main thread). Backed by a
    /// `PendingOutputBuffer` so output that arrives BEFORE the view installs its
    /// render closure, notably Mosh's one-shot first framebuffer diff, emitted
    /// synchronously during connect before `TerminalScreen.makeUIView` runs, is
    /// buffered and replayed on install instead of being silently dropped (which
    /// left the Mosh terminal permanently blank). Setting nil detaches (teardown /
    /// view rebuild); the next non-nil set flushes anything buffered meanwhile.
    var onBytes: (([UInt8]) -> Void)? {
        didSet {
            if let onBytes {
                // Diagnostic: how many bytes were buffered awaiting this sink (a
                // non-zero count on Mosh reattach = frames arrived pre-mount and are
                // being flushed now; zero on a supposed-live reattach with no later
                // output = the blank-screen bug, device 2026-09-06).
                let flushing = renderBuffer.pendingCount
                renderBuffer.attachSink(onBytes)
                // `onBytes` is set from `TerminalScreen.makeUIView` (main actor), but this
                // class is nonisolated (Sendable, fed from the Rust thread), so the
                // @MainActor `DebugLog.shared` needs assumeIsolated (project pattern for the
                // @MainActor callback trap). Safe: the set only happens on main.
                MainActor.assumeIsolated {
                    DebugLog.shared.log(.lifecycle, "output:sink attached flushedPending=\(flushing)B")
                }
            } else {
                renderBuffer.detachSink()
                // Reset the first-chunk diagnostic so `output:firstChunk` fires again on
                // the NEXT sink attach (a reattach detaches via teardown, then the fresh
                // mount re-attaches): without this the counter, living on the VM-lifetime
                // `output`, only ever logged once for the app's whole life.
                diagBytesSeen = 0
                MainActor.assumeIsolated {
                    DebugLog.shared.log(.lifecycle, "output:sink detached")
                }
            }
        }
    }
    /// Buffers render bytes across the pre-install / detached windows. All access is
    /// on the main thread (both `onOutput`'s hop and the `onBytes` didSet run there).
    private var renderBuffer = PendingOutputBuffer()
    /// Set by the view model to harvest output bytes for the predictor (main thread).
    /// A separate slot from `onBytes` because `TerminalScreen.makeUIView` installs
    /// its own render closure into `onBytes`; without this second slot the raw-shell
    /// harvest closure was clobbered and degraded-mode output never trained the
    /// predictor. Both fire from `onOutput`.
    var onHarvestBytes: (([UInt8]) -> Void)?
    /// Set by the view model to learn the session ended (called on the main thread).
    var onExit: ((ShellExit) -> Void)?

    /// Diagnostic: cumulative render bytes seen since the last sink (re)attach cycle,
    /// gating a throttled first-chunk log without per-frame spam. Reset to 0 on sink
    /// detach (teardown), so the `output:firstChunk` log fires once per connection AND
    /// per reattach, not once for the VM-lifetime `output` instance.
    private var diagBytesSeen = 0

    func onOutput(data: Data) {
        let bytes = [UInt8](data)   // UniFFI maps Rust Vec<u8> → Swift Data
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Diagnostic: log the FIRST output chunk (does output arrive at all on a
            // reattach?) and whether a sink is attached to receive it (delivered) or
            // not (buffered = will replay on the next sink attach). Throttled to the
            // first chunk only to avoid per-frame spam; device blank-screen 2026-09-06.
            if self.diagBytesSeen == 0 {
                // Inside DispatchQueue.main.async, so this runs on main; assumeIsolated
                // lets the nonisolated class reach the @MainActor DebugLog (see above).
                MainActor.assumeIsolated {
                    DebugLog.shared.log(.lifecycle,
                        "output:firstChunk \(bytes.count)B sink=\(self.renderBuffer.hasSink ? "attached→deliver" : "none→buffer")")
                }
            }
            self.diagBytesSeen += bytes.count
            // Route render bytes through the buffer: delivered now if a sink is
            // attached, held for replay if not. Harvest is a separate pass-through.
            self.renderBuffer.append(bytes)
            self.onHarvestBytes?(bytes)
        }
    }

    func onClosed(exit: ShellExit) {
        DispatchQueue.main.async { [weak self] in self?.onExit?(exit) }
    }
}

/// The `ShellOutput` handed to the Rust core for ONE SSH shell. Forwards to the
/// view model's long-lived `TerminalShellOutput` only while the session generation it
/// captured at open is still current (`SessionGeneration`). After a Reconnect the old
/// shell's pump keeps running until its channel closes; its trailing bytes and its
/// late `on_closed` are dropped here instead of reaching the new session (whose
/// `onExit` would otherwise fail it and clear its resume record).
final class GenerationGatedShellOutput: ShellOutput {
    private let target: TerminalShellOutput
    private let generation: UInt64
    /// Main-actor check of the captured generation against the view model's current one.
    private let isCurrent: @MainActor (UInt64) -> Bool

    init(target: TerminalShellOutput, generation: UInt64,
         isCurrent: @escaping @MainActor (UInt64) -> Bool) {
        self.target = target
        self.generation = generation
        self.isCurrent = isCurrent
    }

    func onOutput(data: Data) {
        DispatchQueue.main.async { [self] in
            // On main (DispatchQueue.main); assumeIsolated reaches the @MainActor check.
            let live = MainActor.assumeIsolated { isCurrent(generation) }
            guard live else { return }
            // Re-hops to main inside, after this hop: FIFO keeps the byte order.
            target.onOutput(data: data)
        }
    }

    func onClosed(exit: ShellExit) {
        DispatchQueue.main.async { [self] in
            let live = MainActor.assumeIsolated { isCurrent(generation) }
            guard live else {
                MainActor.assumeIsolated {
                    DebugLog.shared.log(.connect, "shell: on_closed from a replaced session → ignored")
                }
                return
            }
            target.onExit?(exit)
        }
    }
}
