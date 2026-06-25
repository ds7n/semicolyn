// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// OpenSSH `PreferredAuthentications` methods, in the spec's vocabulary.
public enum AuthMethod: String, Codable, Equatable, Sendable {
    case publicKey = "publickey"
    case password
    case keyboardInteractive = "keyboard-interactive"
}

/// `mosh.predictionMode` — mosh's local-echo prediction policy.
public enum MoshPredictionMode: String, Codable, Equatable, Sendable {
    case adaptive, always, never, experimental
}

/// `mosh.*` Neotilde extension. `udpPortRange` is a two-element `[lo, hi]` (the
/// spec's `[number, number]`); round-trips losslessly through JSON.
public struct MoshConfig: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var serverPath: String?
    public var udpPortRange: [Int]?
    public var predictionMode: MoshPredictionMode?

    public init(enabled: Bool, serverPath: String? = nil,
                udpPortRange: [Int]? = nil, predictionMode: MoshPredictionMode? = nil) {
        self.enabled = enabled
        self.serverPath = serverPath
        self.udpPortRange = udpPortRange
        self.predictionMode = predictionMode
    }
}

/// `tailscale.*` Neotilde extension.
public struct TailscaleConfig: Codable, Equatable, Sendable {
    public var required: Bool
    public var tailnet: String?

    public init(required: Bool, tailnet: String? = nil) {
        self.required = required
        self.tailnet = tailnet
    }
}

/// `neotilde.predictor.*` — per-host predictor controls.
public struct PredictorConfig: Codable, Equatable, Sendable {
    public var incognito: Bool?

    public init(incognito: Bool? = nil) {
        self.incognito = incognito
    }
}

/// `neotilde.tmux.*` — per-host tmux controls.
public struct TmuxConfig: Codable, Equatable, Sendable {
    public var attemptControlMode: Bool?

    public init(attemptControlMode: Bool? = nil) {
        self.attemptControlMode = attemptControlMode
    }
}

/// `neotilde.osc52.*` — per-host clipboard policy.
public struct Osc52Config: Codable, Equatable, Sendable {
    public var allow: Bool?
    public init(allow: Bool? = nil) { self.allow = allow }
}

/// `neotilde.*` Neotilde-namespaced extension bundle.
public struct NeotildeConfig: Codable, Equatable, Sendable {
    public var predictor: PredictorConfig?
    public var tmux: TmuxConfig?
    public var osc52: Osc52Config?

    public init(predictor: PredictorConfig? = nil, tmux: TmuxConfig? = nil, osc52: Osc52Config? = nil) {
        self.predictor = predictor
        self.tmux = tmux
        self.osc52 = osc52
    }
}
