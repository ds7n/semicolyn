// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import SemicolynKit

/// Off-main-actor owner of the predictor engine. Its serial mailbox IS the FIFO
/// that decouples predictor work from the keystroke send-path: `ConnectionViewModel`
/// writes the byte to the transport, then hands already-echo-classified tokens here
/// via `await`. Consuming (record + vocab, harvest) and `suggestions` run on this
/// actor's executor, never on main; the SwiftTerm grid-reading echo oracle stays on
/// the VM's main actor and never crosses this boundary. Serial isolation preserves
/// the per-line commit/record ordering the L1/L4a invariants require.
actor PredictorActor {
    private var engine: PredictorEngine

    init(engine: PredictorEngine) { self.engine = engine }

    func beginLine() { engine.beginLine() }

    func record(_ tokens: [CommittedToken], echoConfirmed: Bool, optedOut: Bool) {
        for c in tokens {
            engine.record(c.token, after: c.previous,
                          echoConfirmed: echoConfirmed, optedOut: optedOut)
        }
    }

    func suggestions(forPrefix prefix: String, after previous: String?) -> [String] {
        engine.suggestions(forPrefix: prefix, after: previous)
    }

    func harvest(output: String) { engine.harvest(output: output) }

    func snapshotState() -> LearnedState { engine.state }
    func purgeLearned() { engine.purgeLearned() }
    func forgetLastLine() { engine.forgetLastLine() }
}
