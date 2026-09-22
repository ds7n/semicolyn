// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// OpenSSH `PreferredAuthentications` methods, in the spec's vocabulary.
public enum AuthMethod: String, Codable, Equatable, Sendable {
    case publicKey = "publickey"
    case password
    case keyboardInteractive = "keyboard-interactive"
}

/// `mosh.predictionMode`, mosh's local-echo prediction policy.
public enum MoshPredictionMode: String, Codable, Equatable, Sendable {
    case adaptive, always, never, experimental
}

/// `mosh.*` Semicolyn extension. `udpPortRange` is a two-element `[lo, hi]` (the
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

/// `tailscale.*` Semicolyn extension.
public struct TailscaleConfig: Codable, Equatable, Sendable {
    public var required: Bool
    public var tailnet: String?

    public init(required: Bool, tailnet: String? = nil) {
        self.required = required
        self.tailnet = tailnet
    }
}

/// `semicolyn.predictor.*`, per-host predictor controls.
public struct PredictorConfig: Codable, Equatable, Sendable {
    public var incognito: Bool?

    public init(incognito: Bool? = nil) {
        self.incognito = incognito
    }
}

/// `semicolyn.tmux.*`, per-host tmux controls.
public struct TmuxConfig: Codable, Equatable, Sendable {
    /// Whether this host drives tmux via native gestures. nil = inherit (-> Defaults -> true).
    public var useTmux: Bool?
    /// User-chosen tmux session name; nil = inherit (-> Defaults -> "semicolyn").
    public var sessionName: String?
    /// User-chosen tmux prefix key override (e.g. "C-a"); nil = auto-discover. USER-set,
    /// highest precedence; auto-learning never writes this field.
    public var prefixOverride: String?
    /// The tmux prefix (e.g. "C-a") LEARNED automatically from in-band discovery on a
    /// fresh connect, stored per-host so it can be reused on every later resume (where
    /// in-band discovery cannot run: the restored screen is already inside attached tmux).
    /// Distinct from `prefixOverride` (the user's manual setting): learning writes only
    /// this, and `prefixOverride` still wins. nil = never discovered yet.
    public var learnedPrefix: String?
    /// Per-host AUTO-LEARNED tmux action keybindings (action rawValue -> key name,
    /// e.g. "splitHorizontal": "|"), discovered from `list-keys` on a fresh connect
    /// and reused on resume. nil = never discovered. Distinct from user config; a
    /// fresh connect always overwrites it (auto-heals config changes).
    public var learnedActionKeys: [String: String]?

    public init(useTmux: Bool? = nil, sessionName: String? = nil,
                prefixOverride: String? = nil, learnedPrefix: String? = nil,
                learnedActionKeys: [String: String]? = nil) {
        self.useTmux = useTmux
        self.sessionName = sessionName
        self.prefixOverride = prefixOverride
        self.learnedPrefix = learnedPrefix
        self.learnedActionKeys = learnedActionKeys
    }

    private enum CodingKeys: String, CodingKey {
        case useTmux
        case attemptControlMode   // legacy key; decoded as a fallback, never encoded
        case sessionName
        case prefixOverride
        case learnedPrefix
        case learnedActionKeys
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Prefer the new key; fall back to the legacy key so saved hosts are preserved.
        if let v = try c.decodeIfPresent(Bool.self, forKey: .useTmux) {
            self.useTmux = v
        } else {
            self.useTmux = try c.decodeIfPresent(Bool.self, forKey: .attemptControlMode)
        }
        self.sessionName = try c.decodeIfPresent(String.self, forKey: .sessionName)
        self.prefixOverride = try c.decodeIfPresent(String.self, forKey: .prefixOverride)
        self.learnedPrefix = try c.decodeIfPresent(String.self, forKey: .learnedPrefix)
        self.learnedActionKeys = try c.decodeIfPresent([String: String].self, forKey: .learnedActionKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(useTmux, forKey: .useTmux)
        try c.encodeIfPresent(sessionName, forKey: .sessionName)
        try c.encodeIfPresent(prefixOverride, forKey: .prefixOverride)
        try c.encodeIfPresent(learnedPrefix, forKey: .learnedPrefix)
        try c.encodeIfPresent(learnedActionKeys, forKey: .learnedActionKeys)
        // never encodes the legacy attemptControlMode key
    }
}

/// `semicolyn.osc52.*`, per-host clipboard policy.
public struct Osc52Config: Codable, Equatable, Sendable {
    public var allow: Bool?
    public init(allow: Bool? = nil) { self.allow = allow }
}

/// `semicolyn.*` Semicolyn-namespaced extension bundle.
public struct SemicolynConfig: Codable, Equatable, Sendable {
    public var predictor: PredictorConfig?
    public var tmux: TmuxConfig?
    public var osc52: Osc52Config?

    public init(predictor: PredictorConfig? = nil, tmux: TmuxConfig? = nil, osc52: Osc52Config? = nil) {
        self.predictor = predictor
        self.tmux = tmux
        self.osc52 = osc52
    }
}
