// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import SemicolynKit

/// App-side orchestrator for connection resume. Owns the `ResumableSessionStore`
/// (two-tier: encrypted metadata + Keychain secret) and turns the App's lifecycle
/// edges into store writes: `captureConnected` upserts a record at the connected
/// edge, `clear` removes it at every observable end, and `resumeOnLaunch` runs the
/// orphan sweep then the pure `resumeDecision` to tell the UI what to do.
///
/// Thin by design: no reconnect logic lives here (that is the executor in
/// `SessionView`/`ConnectionViewModel`), only persistence + the decision call.
/// SECURITY: the reconnect secret is passed straight to `store.upsert(secret:)`
/// and never logged; `.connect` lines record only lengths / parsed-ok, mirroring
/// the ET IDPASSKEY logging discipline.
@MainActor
final class ResumeCoordinator {
    private let store: ResumableSessionStore

    init(store: ResumableSessionStore) {
        self.store = store
    }

    /// Persist (or refresh) the resumable record for a session that just reached
    /// its connected edge. `secret` is the transport reattach credential (Mosh
    /// `MOSH_KEY`, ET `IDPASSKEY`); nil for raw SSH (which always reconnects fresh
    /// after a prompt). `tmuxSessionName` is non-nil only for a tmux `-CC` session.
    func captureConnected(sessionID: UUID, host: Host, transport: Transport,
                          endpoint: (host: String, port: Int), secret: Data?,
                          tmuxSessionName: String?) {
        let record = ResumableSession(
            sessionID: sessionID, hostID: host.id, transport: transport,
            host: endpoint.host, port: endpoint.port,
            tmuxSessionName: tmuxSessionName, lastConnectedAt: Date())
        do {
            try store.upsert(record, secret: secret)
            DebugLog.shared.log(.connect,
                "resume:capture ok transport=\(transport.rawValue) hasSecret=\(secret != nil) "
                + "tmux=\(tmuxSessionName != nil) endpoint=\(endpoint.host):\(endpoint.port)")
        } catch {
            DebugLog.shared.log(.connect, "resume:capture FAILED error=\(error)")
        }
    }

    /// Remove the resumable record (and its secret slot) for `sessionID`. Called at
    /// every observable end: clean disconnect, teardown, and mid-flight error. Idempotent.
    func clear(sessionID: UUID) {
        do {
            try store.remove(sessionID: sessionID)
            DebugLog.shared.log(.connect, "resume:clear ok sessionID=\(sessionID)")
        } catch {
            DebugLog.shared.log(.connect, "resume:clear FAILED error=\(error)")
        }
    }

    /// Remove EVERY resume record (and secret slot) for `hostID`. Called when a host
    /// is deleted or materially edited: a deleted host has no target, and an edited
    /// host's stored endpoint may be stale, so the record must not survive to drive a
    /// resume. The store has no remove-by-host, so this iterates `all()` and removes by
    /// `sessionID`. Idempotent; logs outcome only (never a secret).
    func clear(hostID: UUID) {
        do {
            let victims = try store.all().filter { $0.hostID == hostID }
            for record in victims {
                try store.remove(sessionID: record.sessionID)
            }
            DebugLog.shared.log(.connect, "resume:clearHost hostID=\(hostID) removed=\(victims.count)")
        } catch {
            DebugLog.shared.log(.connect, "resume:clearHost FAILED hostID=\(hostID) error=\(error)")
        }
    }

    /// Run the launch resume flow: sweep orphans, then decide (pure) how to resume
    /// the most-recent record. Returns the action for the UI to execute. Never throws
    /// into launch: a store read error degrades to `.none` (normal launch).
    func resumeOnLaunch(isWarm: Bool) -> ResumeAction {
        do {
            let pruned = try store.reconcile()
            let record = try store.all().first
            let secretPresent = record.map { store.hasSecret(sessionID: $0.sessionID) } ?? false
            let action = resumeDecision(record: record, isWarm: isWarm, secretPresent: secretPresent)
            DebugLog.shared.log(.connect,
                "resume:onLaunch prunedCount=\(pruned.count) hasRecord=\(record != nil) "
                + "isWarm=\(isWarm) secretPresent=\(secretPresent) action=\(actionLabel(action))")
            return action
        } catch {
            DebugLog.shared.log(.connect, "resume:onLaunch store read FAILED (\(error)) → none")
            return .none
        }
    }

    /// The reconnect secret for `sessionID`, or nil. Read by the cold-reattach
    /// executor to rebuild the Mosh/ET transport. NEVER logged.
    func secret(sessionID: UUID) -> Data? {
        store.secret(sessionID: sessionID)
    }

    /// Privacy-safe label for a `ResumeAction` (never carries a secret): the record's
    /// `coldReattach`/`promptRaw` payload is metadata-only by construction.
    private func actionLabel(_ action: ResumeAction) -> String {
        switch action {
        case .reforeground: return "reforeground"
        case .coldReattach: return "coldReattach"
        case .promptRaw: return "promptRaw"
        case .none: return "none"
        }
    }
}
