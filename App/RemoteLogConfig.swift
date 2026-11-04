// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import UIKit
import SemicolynKit

/// UserDefaults keys + defaults for the remote diagnostics stream. All developer-facing,
/// off by default. `LogTransport` (SemicolynKit) is `RawRepresentable` by `String`, so it
/// persists directly via `@AppStorage`.
enum RemoteLogConfig {
    static let enabledKey = "diagnostics.remoteLog.enabled"
    static let hostKey = "diagnostics.remoteLog.host"
    static let portKey = "diagnostics.remoteLog.port"
    static let transportKey = "diagnostics.remoteLog.transport"
    static let keystrokeContentKey = "diagnostics.remoteLog.keystrokeContent"

    static let defaultPort = 6514
    static let defaultTransport: LogTransport = .tls
}

/// Pinned TLS certificate fingerprints for diagnostics servers, keyed by
/// `remoteLogPinKey(host:port:)` (security audit M3). UserDefaults is thread-safe, so the
/// sink's TLS verify block (on its own queue) reads and writes it directly.
enum RemoteLogCertPins {
    private static let key = "diagnostics.remoteLog.certPins"

    static func pin(for pinKey: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: String])?[pinKey]
    }

    static func setPin(_ fingerprint: String, for pinKey: String) {
        var all = (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
        all[pinKey] = fingerprint
        UserDefaults.standard.set(all, forKey: key)
    }

    static func forget(_ pinKey: String) {
        var all = (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
        all[pinKey] = nil
        UserDefaults.standard.set(all, forKey: key)
    }
}

/// Asks the user, on top of whatever is on screen, whether to trust a diagnostics server
/// whose certificate no longer matches its pin. The sink refuses the connection first;
/// "Trust New Certificate" re-pins and reconnects. A certificate the user declined is not
/// asked about again until the app relaunches (the sink keeps retrying in the background).
@MainActor
enum RemoteLogCertPrompt {
    private static var showing = false
    private static var declined: Set<String> = []

    /// Called from the sink's TLS queue.
    nonisolated static func report(pinKey: String, pinned: String, presented: String) {
        Task { @MainActor in present(pinKey: pinKey, pinned: pinned, presented: presented) }
    }

    private static func present(pinKey: String, pinned: String, presented: String) {
        guard !showing, !declined.contains(presented), let top = topViewController() else { return }
        showing = true
        let alert = UIAlertController(
            title: "Log server certificate changed",
            message: "The diagnostics server \(pinKey) presented a different certificate.\n\n"
                + "Before: \(pinned)\nNow: \(presented)\n\n"
                + "If you didn't replace it, someone may be intercepting your logs. "
                + "Logs are not sent until you decide.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Don't Trust", style: .cancel) { _ in
            declined.insert(presented)
            showing = false
        })
        alert.addAction(UIAlertAction(title: "Trust New Certificate", style: .destructive) { _ in
            RemoteLogCertPins.setPin(presented, for: pinKey)
            showing = false
            DebugLog.shared.restartRemote(reason: "cert-trusted")
        })
        top.present(alert, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        var top = scenes.flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}
