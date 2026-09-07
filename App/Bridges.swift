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

    init(hostID: UUID, trust: HostKeyTrustEvaluator,
         present: @escaping @MainActor (HostKeyPrompt) async -> Bool) {
        self.hostID = hostID; self.trust = trust; self.present = present
    }

    func verify(info: HostKeyInfo) async -> Bool {
        let evaluated = try? trust.evaluate(hostID: hostID, algorithm: info.keyType,
                                            fingerprint: info.fingerprint)
        // DebugLog is @MainActor; verify() is non-isolated async, so these hops need
        // `await`. Fine here, host-key verify runs once per connect, not on any hot
        // path, so the main-actor hop cost is irrelevant.
        if evaluated == nil {
            await DebugLog.shared.log(.connect, "hostkey: trust.evaluate THREW → defaulting to firstTrust")
        }
        let decision = evaluated ?? .firstTrust
        switch decision {
        case .trusted:
            await DebugLog.shared.log(.connect, "hostkey: TRUSTED (\(info.keyType)) → accept, no prompt")
            return true
        case .firstTrust:
            await DebugLog.shared.log(.connect, "hostkey: firstTrust (\(info.keyType)) → prompting user")
            let ok = await present(.firstTrust(hostLabel: info.hostLabel, keyType: info.keyType,
                                               offered: info.fingerprint))
            await DebugLog.shared.log(.connect, "hostkey: firstTrust → user \(ok ? "ACCEPTED (storing trust)" : "REJECTED")")
            if ok { try? trust.trust(hostID: hostID, algorithm: info.keyType,
                                     fingerprint: info.fingerprint, at: Date()) }
            return ok
        case .mismatch(let stored):
            await DebugLog.shared.log(.connect, "hostkey: MISMATCH (\(info.keyType)), stored key differs → prompting user")
            let ok = await present(.mismatch(hostLabel: info.hostLabel, keyType: info.keyType,
                                             stored: stored.first?.fingerprint ?? "",
                                             offered: info.fingerprint))
            await DebugLog.shared.log(.connect, "hostkey: mismatch → user \(ok ? "ACCEPTED (replacing trust)" : "REJECTED")")
            if ok { try? trust.replace(hostID: hostID, algorithm: info.keyType,
                                       fingerprint: info.fingerprint, at: Date()) }
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
