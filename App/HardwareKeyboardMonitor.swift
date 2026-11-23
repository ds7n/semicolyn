// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import GameController

/// Observes hardware-keyboard connect/disconnect via GameController so the keybar
/// can switch to its compact form (or hide) when a physical keyboard is present
/// (external-keyboard spec "Keybar behavior"). `GCKeyboard.coalesced` is the
/// single logical keyboard iOS exposes, or nil when none is attached.
@MainActor
final class HardwareKeyboardMonitor: ObservableObject {
    @Published private(set) var isConnected: Bool

    private var observers: [NSObjectProtocol] = []

    init() {
        isConnected = GCKeyboard.coalesced != nil
        let center = NotificationCenter.default
        // The observer blocks are @Sendable, but `queue: .main` runs them on the main
        // thread, so assumeIsolated reaches the main-actor state (callback-trap pattern).
        observers.append(center.addObserver(forName: .GCKeyboardDidConnect, object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isConnected = true
                DebugLog.shared.log(.input, "input:hwKeyboard connected=true")
            }
        })
        observers.append(center.addObserver(forName: .GCKeyboardDidDisconnect, object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isConnected = GCKeyboard.coalesced != nil
                DebugLog.shared.log(.input, "input:hwKeyboard connected=\(self?.isConnected ?? false)")
            }
        })
    }

    deinit {
        for token in observers { NotificationCenter.default.removeObserver(token) }
    }
}
