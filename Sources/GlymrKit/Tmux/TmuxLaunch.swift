// Sources/GlymrKit/Tmux/TmuxLaunch.swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// A parsed `major.minor` tmux version (patch letters like `3.3a` are ignored).
public struct TmuxVersion: Equatable, Comparable, Sendable {
    public let major: Int
    public let minor: Int
    public init(major: Int, minor: Int) { self.major = major; self.minor = minor }
    public static func < (l: TmuxVersion, r: TmuxVersion) -> Bool {
        (l.major, l.minor) < (r.major, r.minor)
    }
}

/// Parses `tmux -V` output (e.g. "tmux 3.3a", "tmux next-3.5") to `major.minor`,
/// or nil when no `<int>.<int>` version token is present.
public func parseTmuxVersion(_ probeOutput: String) -> TmuxVersion? {
    // Find the first token matching <digits>.<digits>, ignoring any trailing letters.
    for token in probeOutput.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "-" }) {
        let digits = token.prefix { $0.isNumber || $0 == "." }
        let parts = digits.split(separator: ".")
        if parts.count >= 2, let maj = Int(parts[0]), let min = Int(parts[1]) {
            return TmuxVersion(major: maj, minor: min)
        }
    }
    return nil
}

/// Control mode needs tmux ≥ 3.0 (roadmap constraint).
public func tmuxSupportsControlMode(_ v: TmuxVersion) -> Bool {
    v >= TmuxVersion(major: 3, minor: 0)
}

/// Why Glymr fell back to a raw-PTY shell instead of attaching control mode.
public enum DegradeReason: Equatable, Sendable {
    case optedOut                 // host's glymr.tmux.attemptControlMode == false
    case tmuxNotFound             // probe empty / unparseable
    case tooOld(TmuxVersion)      // tmux < 3.0
}

/// The connect-time launch decision.
public enum TmuxLaunchDecision: Equatable, Sendable {
    case attach
    case degrade(DegradeReason)
}

/// Decide whether to attach control mode given the host's opt-in flag and the
/// captured `tmux -V` output (nil when the probe produced nothing).
public func tmuxLaunchDecision(attemptControlMode: Bool, versionProbe: String?) -> TmuxLaunchDecision {
    guard attemptControlMode else { return .degrade(.optedOut) }
    guard let probe = versionProbe, let v = parseTmuxVersion(probe) else { return .degrade(.tmuxNotFound) }
    return tmuxSupportsControlMode(v) ? .attach : .degrade(.tooOld(v))
}

/// Supplies the shared tmux session name. The real implementation derives it from
/// the iCloud-account-bound CloudKit key (2b-ii, enrollment-gated); Plan A uses a
/// local stub seed.
public protocol SessionNameProvider {
    func sessionName() -> String
}

/// `glymr-<first 8 lowercase hex of SHA-256(seed)>`.
public func tmuxSessionName(seed: String) -> String {
    let digest = SHA256.hash(data: Data(seed.utf8))
    let hex = digest.map { String(format: "%02x", $0) }.joined()
    return "glymr-" + hex.prefix(8)
}

/// Stub provider: a deterministic name from a local seed. Swap for a
/// CloudKit-key-derived provider in 2b-ii.
public struct StubSessionNameProvider: SessionNameProvider {
    public let seed: String
    public init(seed: String) { self.seed = seed }
    public func sessionName() -> String { tmuxSessionName(seed: seed) }
}
