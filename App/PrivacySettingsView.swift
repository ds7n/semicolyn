// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import SemicolynKit

/// Settings → Suggestions & Privacy: the all-hosts "Don't learn from my typing"
/// default (the same Connection Defaults value; a host can still override it in its
/// editor), the predictor panic-purge ("Clear Learned Suggestions…"), and a read-only
/// "Keystroke logging" row that links to Diagnostics, where it is changed.
///
/// Purge wiring: `AppStores.shared.purgePredictorLearned()` resets the live
/// session's in-memory engine (via the `activePredictorSession` registration) BEFORE
/// deleting the on-disk store. So a purge is complete whether Settings is reached
/// from the host list (no session) or mid-session; there is no stale-write-back
/// window. The bundled seed suggestions (shipped app content, no secret) remain.
struct PrivacySettingsView: View {
    /// Edits the Defaults record live, like Connection Defaults.
    @StateObject private var defaultsVM = DefaultsEditorViewModel()
    @State private var confirming = false
    @State private var purged = false

    @AppStorage(DiagnosticsContent.loggingEnabledKey) private var loggingEnabled = false
    @AppStorage(LogCategory.input.storageKey) private var inputCategoryOn = LogCategory.input.defaultOn
    @AppStorage(RemoteLogConfig.keystrokeContentKey) private var keystrokeContent = false

    var body: some View {
        List {
            Section {
                Toggle(isOn: Binding(
                    get: { defaultsVM.defaults.semicolyn.value?.predictor?.incognito ?? false },
                    set: { newIncognito in
                        var cfg = defaultsVM.defaults.semicolyn.value ?? SemicolynConfig()
                        var predictor = cfg.predictor ?? PredictorConfig()
                        predictor.incognito = newIncognito
                        cfg.predictor = predictor
                        defaultsVM.defaults.semicolyn = .explicit(cfg)
                    }
                )) {
                    Text(privateModeLabel)
                }
            } header: {
                Text("Suggestions")
            } footer: {
                Text("Applies to every host unless the host changes it. Word suggestions still appear from the built-in dictionary.")
            }

            Section {
                Button(role: .destructive) { InputClickFeedback.play(); confirming = true } label: {
                    Label("Clear Learned Suggestions…", systemImage: "trash")
                }
            } footer: {
                Text("Removes words learned from your typing. Built-in suggestions stay.")
            }

            Section {
                NavigationLink {
                    DiagnosticsSettingsView()
                } label: {
                    LabeledContent("Keystroke logging",
                                   value: keystrokeLoggingSummary(loggingEnabled: loggingEnabled,
                                                                  inputCategoryOn: inputCategoryOn,
                                                                  contentOn: keystrokeContent))
                }
            } footer: {
                Text("Change it in Diagnostics.")
            }
        }
        .navigationTitle("Suggestions & Privacy")
        .confirmationDialog("Clear learned suggestions?",
                            isPresented: $confirming, titleVisibility: .visible) {
            Button("Clear", role: .destructive) {
                InputClickFeedback.play()
                try? AppStores.shared.purgePredictorLearned()
                purged = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone. Built-in suggestions are kept.")
        }
        .alert("Learned suggestions cleared", isPresented: $purged) {
            Button("OK", role: .cancel) { InputClickFeedback.play() }
        }
        .alert("Couldn't save", isPresented: Binding(
            get: { defaultsVM.saveError != nil },
            set: { if !$0 { defaultsVM.saveError = nil } }
        )) {
            Button("OK", role: .cancel) { InputClickFeedback.play(); defaultsVM.saveError = nil }
        } message: {
            Text(defaultsVM.saveError ?? "")
        }
    }
}
