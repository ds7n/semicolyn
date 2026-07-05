// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

/// Privacy controls. v1 surfaces the predictor panic-purge — the honest, complete
/// "forget everything it learned" reset. Wipes user-derived learned state only; the
/// bundled seed suggestions (shipped app content, no secret) remain.
///
/// Wiring note: this view calls `AppStores.shared.purgePredictorLearned()` directly
/// for the disk wipe (Settings is reachable from the host list, with no live
/// `ConnectionViewModel`). If it is ever presented over a live session, that
/// session's engine is separately reset on next `startPredictor`/`teardown`; a
/// stale in-memory engine writing back on a background task is the only edge —
/// acceptable for v1 (the file is re-deleted on next purge and the next launch
/// loads empty). Use `ConnectionViewModel.panicPurge()` from session UI if the live
/// engine also needs immediate reset.
struct PrivacySettingsView: View {
    @State private var confirming = false
    @State private var purged = false

    var body: some View {
        List {
            Section {
                Button(role: .destructive) { confirming = true } label: {
                    Label("Forget everything the predictor learned", systemImage: "trash")
                }
            } footer: {
                Text("Removes everything the keyboard predictor learned from what you typed. The built-in suggestions remain.")
            }
        }
        .navigationTitle("Privacy")
        .confirmationDialog("Forget the predictor's learned words?",
                            isPresented: $confirming, titleVisibility: .visible) {
            Button("Forget Everything", role: .destructive) {
                try? AppStores.shared.purgePredictorLearned()
                purged = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone. Built-in suggestions are kept.")
        }
        .alert("Predictor memory cleared", isPresented: $purged) {
            Button("OK", role: .cancel) {}
        }
    }
}
