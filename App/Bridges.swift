// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import NeotildeKit
import NeotildeSSHCoreFFI

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
        let decision = (try? trust.evaluate(hostID: hostID, algorithm: info.keyType,
                                            fingerprint: info.fingerprint)) ?? .firstTrust
        switch decision {
        case .trusted:
            return true
        case .firstTrust:
            let ok = await present(.firstTrust(hostLabel: info.hostLabel, keyType: info.keyType,
                                               offered: info.fingerprint))
            if ok { try? trust.trust(hostID: hostID, algorithm: info.keyType,
                                     fingerprint: info.fingerprint, at: Date()) }
            return ok
        case .mismatch(let stored):
            let ok = await present(.mismatch(hostLabel: info.hostLabel, keyType: info.keyType,
                                             stored: stored.first?.fingerprint ?? "",
                                             offered: info.fingerprint))
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
    /// Set by the terminal view to render output bytes (called on the main thread).
    var onBytes: (([UInt8]) -> Void)?
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
            self?.onBytes?(bytes)
            self?.onHarvestBytes?(bytes)
        }
    }

    func onClosed(exit: ShellExit) {
        DispatchQueue.main.async { [weak self] in self?.onExit?(exit) }
    }
}
