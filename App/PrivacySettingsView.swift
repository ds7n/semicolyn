// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

/// Privacy controls. v1 surfaces the predictor panic-purge — the honest, complete
/// "forget everything it learned" reset. Wipes user-derived learned state only; the
/// bundled seed suggestions (shipped app content, no secret) remain.
///
/// Wiring note: this view calls `AppStores.shared.purgePredictorLearned()`, which
/// resets the live session's in-memory engine (via the `activePredictorSession`
/// registration) BEFORE deleting the on-disk store. So a purge is complete whether
/// Settings is reached from the host list (no session) or mid-session — there is no
/// stale-write-back window.
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
