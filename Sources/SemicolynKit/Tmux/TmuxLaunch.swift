// Sources/SemicolynKit/Tmux/TmuxLaunch.swift
// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

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

/// The minimum tmux Semicolyn launches on SSH: 3.0 (the floor carried over from the
/// control-mode era; the gesture layer's bindings are exercised against 3.x).
public func tmuxMeetsMinimumVersion(_ v: TmuxVersion) -> Bool {
    v >= TmuxVersion(major: 3, minor: 0)
}

/// Why Semicolyn fell back to a raw shell instead of launching tmux.
public enum DegradeReason: Equatable, Sendable {
    case optedOut                 // host's semicolyn.tmux.useTmux == false
    case tmuxNotFound             // probe empty / unparseable
    case tooOld(TmuxVersion)      // tmux < 3.0
    case couldNotStart            // the tmux launch command couldn't be built (e.g. an
                                  // invalid resolved session name), so tmux never launched
}

/// The connect-time launch decision.
public enum TmuxLaunchDecision: Equatable, Sendable {
    case attach
    case degrade(DegradeReason)
}

/// Decide whether to launch tmux given the host's opt-in flag and the
/// captured `tmux -V` output (nil when the probe produced nothing).
public func tmuxLaunchDecision(useTmux: Bool, versionProbe: String?) -> TmuxLaunchDecision {
    guard useTmux else { return .degrade(.optedOut) }
    guard let probe = versionProbe, let v = parseTmuxVersion(probe) else { return .degrade(.tmuxNotFound) }
    return tmuxMeetsMinimumVersion(v) ? .attach : .degrade(.tooOld(v))
}
