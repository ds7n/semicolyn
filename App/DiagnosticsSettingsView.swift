// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import SemicolynKit

/// The Diagnostics sections + their state, factored out of `DiagnosticsSettingsView` so they
/// can be embedded inside any parent `List` while the diagnostics code stays in this file.
/// Owns all diagnostics `@State`/`@AppStorage`; renders its 5 `Section`s (via `body`) plus the
/// keystroke confirmation dialog. Embed with `DiagnosticsContent()` directly inside a parent
/// `List` (a `View` inside `List` flattens to its sections). `DiagnosticsSettingsView`
/// (Settings > Diagnostics) is the thin standalone wrapper around it.
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
    /// to off and re-showed the dialog, the "popup re-pops after Turn On" bug).
    @State private var confirmedKeystroke = false

    /// The pinned certificate of the configured server (re-read after Forget).
    @State private var pinnedCert: String?

    private var transport: LogTransport { LogTransport(rawValue: transportRaw) ?? .tls }

    private var destination: RemoteLogDestination {
        RemoteLogDestination(enabled: remoteEnabled, host: remoteHost, port: remotePort, transport: transport)
    }

    private var pinKey: String { remoteLogPinKey(host: remoteHost, port: remotePort) }

    /// The stream was redirected from `old`: keystroke content logging switches off (turning
    /// it back on asks for Face ID), then the sink is rebuilt. Security audit M3.
    private func destinationChanged(from old: RemoteLogDestination) {
        if keystrokeContent,
           !keystrokeContentAfterDestinationChange(contentOn: true, old: old, new: destination) {
            keystrokeContent = false
            DebugLog.shared.log(.lifecycle, "diagnostics: stream destination changed → keystroke content OFF")
        }
        pinnedCert = RemoteLogCertPins.pin(for: pinKey)
        rebuildSink()
    }

    /// The warning's "Turn On": verify the owner, then enable.
    private func confirmKeystrokeContent() {
        Task {
            do {
                try await KeyAccessAuthorizer.shared.verifyOwner(
                    identityName: "keystroke logging", reason: "Turn on keystroke logging")
            } catch KeyAccessError.unavailable {
                // No passcode on the device: nothing to verify against (same as the key
                // policy screen). Proceed.
            } catch {
                DebugLog.shared.log(.lifecycle, "diagnostics: keystroke content enable refused (\(error))")
                return
            }
            confirmedKeystroke = true      // let the resulting onChange pass through
            keystrokeContent = true
        }
    }

    /// The sections only (no enclosing `List`): the parent supplies the `List`/`Form`
    /// (`DiagnosticsSettingsView`). The keystroke confirmation dialog + logging reapply ride
    /// on the section group so they travel with it.
    var body: some View {
        Group {
            Section {
                Toggle("Enable logging", isOn: $loggingEnabled)
                    .onChange(of: loggingEnabled) { _, _ in
                        DebugLog.shared.configureFromDefaults(reason: "toggle")
                    }
            } footer: {
                Text("When off, nothing is recorded. Turn on, then choose where logs go below.")
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
                    .onChange(of: remoteEnabled) { old, _ in
                        var prior = destination; prior.enabled = old
                        destinationChanged(from: prior)
                    }
                if remoteEnabled {
                    LabeledContent("Server") {
                        TextField("logs.example.com", text: $remoteHost)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                            .onChange(of: remoteHost) { old, _ in
                                var prior = destination; prior.host = old
                                destinationChanged(from: prior)
                            }
                    }
                    LabeledContent("Port") {
                        TextField("6514", value: $remotePort, format: .number.grouping(.never))
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .onChange(of: remotePort) { old, _ in
                                var prior = destination; prior.port = old
                                destinationChanged(from: prior)
                            }
                    }
                    // "Protocol", not "Transport": avoids a clash with the connection type.
                    Picker("Protocol", selection: $transportRaw) {
                        Text("TLS (recommended)").tag(LogTransport.tls.rawValue)
                        Text("TCP").tag(LogTransport.tcp.rawValue)
                        Text("UDP (may cut long lines)").tag(LogTransport.udp.rawValue)
                    }
                    .onChange(of: transportRaw) { old, _ in
                        var prior = destination; prior.transport = LogTransport(rawValue: old) ?? .tls
                        destinationChanged(from: prior)
                    }
                    if transport == .tls {
                        if let pinnedCert {
                            LabeledContent("Certificate") {
                                Text(pinnedCert)
                                    .font(.caption.monospaced())
                                    .lineLimit(1).truncationMode(.middle)
                                    .textSelection(.enabled)
                            }
                            Button("Forget Certificate", role: .destructive) {
                                // Accepting a different server is a redirect too: content
                                // logging goes off (re-enabling asks for Face ID).
                                keystrokeContent = false
                                RemoteLogCertPins.forget(pinKey)
                                self.pinnedCert = nil
                                DebugLog.shared.restartRemote(reason: "cert-forgotten")
                            }
                        } else {
                            LabeledContent("Certificate", value: "Remembered on first connect")
                        }
                    }
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
                Text("Sends diagnostic logs to your own syslog server (RFC 5424). TLS remembers "
                     + "the server's certificate the first time and asks you if it changes. "
                     + "TCP and UDP are unencrypted, so typed keys are never sent over them.")
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
                     + "actual keys are logged too, shown in the debug panel and streamed over "
                     + "TLS only; password prompts are redacted. Turning it on asks for Face ID, "
                     + "a red \"Logging keys\" label shows in sessions while it's on, and "
                     + "changing where logs stream turns it off. Off by default.")
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
                Text("Which events are recorded. Gesture, Input, Predictor, Keybar and Transport "
                     + "are verbose and off by default.")
            }
            }
            .disabled(!loggingEnabled)
        }
        .onAppear {
            DebugLog.shared.configureFromDefaults(reason: "diagnostics")
            pinnedCert = RemoteLogCertPins.pin(for: pinKey)
        }
        .confirmationDialog("Log keystroke content?", isPresented: $showKeystrokeNag, titleVisibility: .visible) {
            Button("Turn On", role: .destructive) { confirmKeystrokeContent() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Records what you type, and streams it to your log server over TLS if remote "
                 + "logging is on. Password prompts are hidden, but passwords or tokens typed "
                 + "on a command line (like mysql -p…) are not. Only use this while "
                 + "troubleshooting.")
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
        let sink = RemoteLogSink(host: remoteHost, port: remotePort, transport: transport, connect: false)
        sink.test { ok in
            DispatchQueue.main.async {
                testResult = ok ? .connected : .failed
                pinnedCert = RemoteLogCertPins.pin(for: pinKey)   // a first connect pins it
            }
        }
    }
}

/// Settings → Diagnostics: the `DiagnosticsContent` sections wrapped in their own `List` +
/// title.
struct DiagnosticsSettingsView: View {
    var body: some View {
        List { DiagnosticsContent() }
            .navigationTitle("Diagnostics")
    }
}
