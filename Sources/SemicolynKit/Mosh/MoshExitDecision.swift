// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// How a Mosh loop exit should be handled by `ConnectionViewModel`. Extracted here
/// (pure, Linux-tested) so the decision is covered off the Apple-only bridge gate.
///
/// The former `firstFrameSeen` discriminator was removed: real mosh emits an
/// init/clear framebuffer diff BEFORE the UDP handshake is confirmed, so
/// `onFirstFrame` fired for a connection that then failed — a device trace showed a
/// nonzero exit 90ms after `onFirstFrame`, wrongly routed to the crash banner. Exit
/// reason + elapsed time classify correctly instead.
public enum MoshExitDecision: Equatable, Sendable {
    /// Handshake never really came up (nonzero exit inside the grace window) →
    /// SSH on the retained connection + banner.
    case fallbackSSH
    /// A live session died (nonzero exit after the grace window) → mid-session crash banner.
    case crashBanner
    /// Clean exit (rc == 0, `nil` reason) → session ended normally.
    case ended
}

/// Classify a Mosh loop exit.
/// - Parameters:
///   - reason: the `onEnd` reason string; `nil` ⟺ a clean (rc == 0) exit.
///   - elapsed: seconds from `sess.start()` to `onEnd`.
///   - graceWindow: the handshake grace window (half-open: `elapsed < graceWindow`
///     is a handshake failure). Default 3.0s.
public func moshExitDecision(reason: String?, elapsed: TimeInterval,
                             graceWindow: TimeInterval = 3.0) -> MoshExitDecision {
    guard reason != nil else { return .ended }
    return elapsed < graceWindow ? .fallbackSSH : .crashBanner
}

/// The first-frame watchdog action. The exit timer only fires when mosh *exits*; a
/// hung UDP path where `mosh_main` neither renders a frame nor returns leaves a
/// permanent blank screen. The App arms a watchdog after `sess.start()`; if no
/// callback (`onFirstFrame` or `onEnd`) has fired by the deadline, fall back to SSH.
public enum MoshWatchdogAction: Equatable, Sendable {
    case fallbackSSH
    case noop
}

/// Decide the watchdog action given whether the loop signalled any life by the deadline.
public func moshWatchdogAction(sawAnyCallback: Bool) -> MoshWatchdogAction {
    sawAnyCallback ? .noop : .fallbackSSH
}
