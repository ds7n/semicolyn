// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import SemicolynKit

/// The Diagnostics sections + their state, factored out of `DiagnosticsSettingsView` so they
/// can be embedded INLINE in `ExperimentalSettingsView` (one screen, no nested navigation)
/// while the diagnostics code stays in this file. Owns all diagnostics `@State`/`@AppStorage`;
/// renders its 5 `Section`s (via `body`) plus the keystroke confirmation dialog. Embed with
/// `DiagnosticsContent()` directly inside a parent `List` (a `View` inside `List` flattens to
/// its sections). `DiagnosticsSettingsView` is now a thin standalone wrapper around it.
struct DiagnosticsContent: View {
    /// MASTER logging switch. Independent of destination (panel / remote): when off,
    /// nothing is recorded anywhere.
    static let loggingEnabledKey = "diagnostics.loggingEnabled"
    static let showDebugPanelKey = "diagnostics.showDebugPanel"
    @AppStorage(Self.loggingEnabledKey) private var loggingEnabled = false
    @AppStorage(Self.showDebugPanelKey) private var showDebugPanel = false

    @AppStorage(RemoteLogConfig.enabledKey) private var remoteEnabled = false
    @AppStorage(RemoteLogConfig.hostKey) private var remoteHost = ""
    @AppStorage(RemoteLogConfig.portKey) private var remotePort = RemoteLogConfig.defaultPort
    @AppStorage(RemoteLogConfig.transportKey) private var transportRaw = RemoteLogConfig.defaultTransport.rawValue
    @AppStorage(RemoteLogConfig.keystrokeContentKey) private var keystrokeContent = false

    /// Result of the last "Test connection", driving both the label text and its color.
    enum TestResult {
        case testing
        case connected
        case failed
        case needsHost

        var text: String {
            switch self {
            case .testing: return "Testing…"
            case .connected: return "✓ Connected"
            case .failed: return "✗ Failed"
            case .needsHost: return "Enter a host first."
            }
        }

        /// Color-coded but still legible on the grouped-list background: a readable green /
        /// red for the terminal states, secondary (system gray) for the transient/neutral.
        var color: Color {
            switch self {
            case .connected: return .green
            case .failed: return .red
            case .testing, .needsHost: return .secondary
            }
        }
    }

    @State private var testResult: TestResult?
    @State private var showKeystrokeNag = false
    /// True only for the single `keystrokeContent` change that the nag's "Turn On"
    /// causes, so that confirmation doesn't re-trigger the nag (which re-set the value
    /// to off and re-showed the dialog — the "popup re-pops after Turn On" bug).
    @State private var confirmedKeystroke = false

    private var transport: LogTransport { LogTransport(rawValue: transportRaw) ?? .tls }

    /// The sections only (no enclosing `List`): the parent supplies the `List`/`Form` so this
    /// can render standalone (via `DiagnosticsSettingsView`) OR inline inside another screen
    /// (`ExperimentalSettingsView`). The keystroke confirmation dialog + logging reapply ride
    /// on the section group so they travel with it in both hosts.
    var body: some View {
        Group {
            Section {
                Toggle("Enable logging", isOn: $loggingEnabled)
                    .onChange(of: loggingEnabled) { _, _ in
                        DebugLog.shared.configureFromDefaults(reason: "toggle")
                    }
            } footer: {
                Text("Master switch. When off, nothing is recorded — to the panel or the "
                     + "remote stream. Turn on, then pick destinations below. Off by default.")
            }

            // Everything below depends on the master switch: gray it all out (non-interactive
            // + dimmed) when logging is off, so it reads as "these do nothing until you enable
            // logging" instead of looking independently settable.
            Group {
            Section {
                Toggle("Show debug log panel", isOn: $showDebugPanel)
            } footer: {
                Text("A destination for logs (requires \"Enable logging\"). Adds a 🐞 button in "
                     + "a connected session that opens a scrollable log with a Copy button.")
            }

            Section {
                Toggle("Enable remote log stream", isOn: $remoteEnabled)
                    .onChange(of: remoteEnabled) { _, _ in rebuildSink() }
                if remoteEnabled {
                    TextField("Host", text: $remoteHost)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .onChange(of: remoteHost) { _, _ in rebuildSink() }
                    TextField("Port", value: $remotePort, format: .number.grouping(.never))
                        .keyboardType(.numberPad)
                        .onChange(of: remotePort) { _, _ in rebuildSink() }
                    Picker("Transport", selection: $transportRaw) {
                        Text("UDP (514)").tag(LogTransport.udp.rawValue)
                        Text("TCP (514)").tag(LogTransport.tcp.rawValue)
                        Text("TLS (6514)").tag(LogTransport.tls.rawValue)
                    }
                    .onChange(of: transportRaw) { _, _ in rebuildSink() }
                    Button("Test connection") { runTest() }
                    if let testResult {
                        Text(testResult.text)
                            .font(.footnote)
                            .foregroundStyle(testResult.color)
                    }
                }
            } header: {
                Text("Stream logs to a server")
            } footer: {
                Text("A destination for logs (requires \"Enable logging\"). Streams the verbose "
                     + "trace off-device as RFC 5424 syslog. Receiver: see tools/syslog-sink "
                     + "(docker compose up). TLS uses a self-signed cert (verification off).")
            }

            Section {
                Toggle("Log keystroke content", isOn: $keystrokeContent)
                    .onChange(of: keystrokeContent) { _, on in
                        // The dialog's "Turn On" sets `keystrokeContent = true`, which
                        // re-fires this onChange. `confirmedKeystroke` suppresses that one
                        // re-entry so confirming actually sticks instead of re-popping the
                        // nag. A genuine user toggle-on (confirmedKeystroke == false) resets
                        // to off and shows the dialog.
                        if on {
                            if confirmedKeystroke {
                                confirmedKeystroke = false   // consume the confirmation
                            } else {
                                keystrokeContent = false
                                showKeystrokeNag = true
                            }
                        }
                    }
            } footer: {
                Text("Off: only structural key events (lengths, backspace) are logged. On: the "
                     + "actual keys are logged too — password/prompt lines are still redacted "
                     + "(shown as REDACTED, never dropped). Off by default.")
            }

            Section {
                ForEach(LogCategory.allCases, id: \.self) { cat in
                    Toggle(isOn: categoryBinding(cat)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(cat.label)
                            Text(cat.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Log categories")
            } footer: {
                Text("Which diagnostic categories are recorded. Low-volume categories are on "
                     + "by default; render/input/predictor/keybar are verbose and off by default.")
            }
            }
            .disabled(!loggingEnabled)
        }
        .onAppear {
            DebugLog.shared.configureFromDefaults(reason: "diagnostics")
        }
        .confirmationDialog("Log keystroke content?", isPresented: $showKeystrokeNag, titleVisibility: .visible) {
            Button("Turn On", role: .destructive) {
                confirmedKeystroke = true      // let the resulting onChange pass through
                keystrokeContent = true
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Diagnostic traces will include the actual keys you type, including anything "
                 + "sensitive, and stream to your configured host if remote logging is on. "
                 + "Password/prompt lines are still redacted.")
        }
    }

    private func categoryBinding(_ cat: LogCategory) -> Binding<Bool> {
        Binding(
            get: { UserDefaults.standard.object(forKey: cat.storageKey) as? Bool ?? cat.defaultOn },
            set: { UserDefaults.standard.set($0, forKey: cat.storageKey)
                   DebugLog.shared.refreshEnabledCategories() }
        )
    }

    /// Re-apply the full logging config (master gate + sink + categories) from the just-
    /// written settings. Routes through the single `configureFromDefaults` path so the
    /// sink signature stays consistent with the foreground/launch reapply.
    private func rebuildSink() {
        DebugLog.shared.configureFromDefaults(reason: "settings")
    }

    private func runTest() {
        guard !remoteHost.isEmpty else { testResult = .needsHost; return }
        testResult = .testing
        let sink = RemoteLogSink(host: remoteHost, port: remotePort, transport: transport)
        sink.test { ok in
            DispatchQueue.main.async { testResult = ok ? .connected : .failed }
        }
    }
}

/// Standalone Settings → Diagnostics screen: the `DiagnosticsContent` sections wrapped in
/// their own `List` + title. Kept for any direct navigation to Diagnostics; the Experimental
/// screen embeds `DiagnosticsContent` inline instead of linking here.
struct DiagnosticsSettingsView: View {
    var body: some View {
        List { DiagnosticsContent() }
            .navigationTitle("Diagnostics")
    }
}
