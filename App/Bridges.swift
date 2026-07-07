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
        if evaluated == nil {
            DebugLog.shared.log("hostkey: trust.evaluate THREW → defaulting to firstTrust")
        }
        let decision = evaluated ?? .firstTrust
        switch decision {
        case .trusted:
            DebugLog.shared.log("hostkey: TRUSTED (\(info.keyType)) → accept, no prompt")
            return true
        case .firstTrust:
            DebugLog.shared.log("hostkey: firstTrust (\(info.keyType)) → prompting user")
            let ok = await present(.firstTrust(hostLabel: info.hostLabel, keyType: info.keyType,
                                               offered: info.fingerprint))
            DebugLog.shared.log("hostkey: firstTrust → user \(ok ? "ACCEPTED (storing trust)" : "REJECTED")")
            if ok { try? trust.trust(hostID: hostID, algorithm: info.keyType,
                                     fingerprint: info.fingerprint, at: Date()) }
            return ok
        case .mismatch(let stored):
            DebugLog.shared.log("hostkey: MISMATCH (\(info.keyType)) — stored key differs → prompting user")
            let ok = await present(.mismatch(hostLabel: info.hostLabel, keyType: info.keyType,
                                             stored: stored.first?.fingerprint ?? "",
                                             offered: info.fingerprint))
            DebugLog.shared.log("hostkey: mismatch → user \(ok ? "ACCEPTED (replacing trust)" : "REJECTED")")
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
    /// render closure — notably Mosh's one-shot first framebuffer diff, emitted
    /// synchronously during connect before `TerminalScreen.makeUIView` runs — is
    /// buffered and replayed on install instead of being silently dropped (which
    /// left the Mosh terminal permanently blank). Setting nil detaches (teardown /
    /// view rebuild); the next non-nil set flushes anything buffered meanwhile.
    var onBytes: (([UInt8]) -> Void)? {
        didSet {
            if let onBytes {
                renderBuffer.attachSink(onBytes)
            } else {
                renderBuffer.detachSink()
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

    func onOutput(data: Data) {
        let bytes = [UInt8](data)   // UniFFI maps Rust Vec<u8> → Swift Data
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
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
