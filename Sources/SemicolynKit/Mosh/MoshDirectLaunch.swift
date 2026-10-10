// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Mosh direct launch: on a fresh connect, mosh-server runs `plainTmuxDirectLaunchCommand`
/// as its session command. If tmux is not on that non-interactive PATH, the script prints
/// `plainTmuxNoTmuxMarker(nonce:)` and execs the user's login shell, and the App falls back
/// ONCE to typing the in-band launch there. The per-connection nonce plus the bounded
/// window below keep a marker that merely APPEARS on screen (e.g. this repo's source in a
/// restored tmux pane) from typing a launch line into the user's foreground program.

/// Seconds after the direct launch's first frame during which the marker can trigger the
/// fallback. The script prints it within milliseconds of starting, so anything later is
/// screen content, not the script.
public let moshDirectLaunchFallbackWindowSeconds: Double = 5.0

/// Characters a launch nonce may use (ASCII letters and digits only).
private let moshLaunchNonceAlphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")

/// A nonce is valid iff it is 1...16 ASCII letters/digits, so it is safe to interpolate
/// unquoted into the single-quoted direct launch script.
public func isValidMoshLaunchNonce(_ nonce: String) -> Bool {
    guard (1...16).contains(nonce.unicodeScalars.count) else { return false }
    return nonce.unicodeScalars.allSatisfy { s in
        (s >= "a" && s <= "z") || (s >= "A" && s <= "Z") || (s >= "0" && s <= "9")
    }
}

/// A fresh random per-connection nonce (`length` letters/digits, default 8) from the
/// system CSPRNG. Not a secret: it only makes the marker unguessable for screen content.
public func makeMoshLaunchNonce(length: Int = 8) -> String {
    precondition((1...16).contains(length), "makeMoshLaunchNonce: length must be 1...16")
    var rng = SystemRandomNumberGenerator()
    return String((0..<length).map { _ in moshLaunchNonceAlphabet.randomElement(using: &rng)! })
}

/// Everything the fallback decision reads, snapshotted by the App per output chunk.
public struct MoshDirectLaunchFallbackInput: Equatable, Sendable {
    /// Direct-launch output accumulated so far (bounded by the App).
    public var output: String
    /// This connection's nonce, the one baked into the direct launch script.
    public var nonce: String
    /// The fallback already fired for this connection.
    public var alreadyFired: Bool
    /// The direct launch evidently attached tmux (mouse mode on, or the overlay revealed
    /// on `mouseMode`/`sentinelQuiet`).
    public var attached: Bool
    /// Seconds since the direct launch's first frame.
    public var secondsSinceFirstFrame: Double

    public init(output: String, nonce: String, alreadyFired: Bool, attached: Bool,
                secondsSinceFirstFrame: Double) {
        self.output = output
        self.nonce = nonce
        self.alreadyFired = alreadyFired
        self.attached = attached
        self.secondsSinceFirstFrame = secondsSinceFirstFrame
    }

    /// Whether `output` carries this connection's exact marker.
    public var markerSeen: Bool { containsPlainTmuxNoTmuxMarker(output, nonce: nonce) }
}

/// Fire the in-band fallback iff it has not fired yet, tmux has not attached, the first
/// frame is under `moshDirectLaunchFallbackWindowSeconds` old, and the output carries
/// `SEMICOLYN_NOTMUX_<nonce>` exactly.
public func shouldFireMoshDirectLaunchFallback(_ input: MoshDirectLaunchFallbackInput) -> Bool {
    guard !input.alreadyFired, !input.attached,
          input.secondsSinceFirstFrame < moshDirectLaunchFallbackWindowSeconds else { return false }
    return input.markerSeen
}

/// The decision-point log line, e.g.
/// `mosh:directFallback marker=true fired=false attached=false t=0.42s → fire=true`.
public func moshDirectLaunchFallbackLogLine(_ input: MoshDirectLaunchFallbackInput, fire: Bool) -> String {
    decisionLine("mosh:directFallback",
                 inputs: [("marker", "\(input.markerSeen)"),
                          ("fired", "\(input.alreadyFired)"),
                          ("attached", "\(input.attached)"),
                          ("t", String(format: "%.2fs", input.secondsSinceFirstFrame))],
                 outputs: [("fire", "\(fire)")])
}
