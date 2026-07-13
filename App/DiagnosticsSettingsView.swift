// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import SemicolynKit

/// Settings → Diagnostics. Gates the on-screen debug panel AND the off-device log stream.
struct DiagnosticsSettingsView: View {
    static let showDebugPanelKey = "diagnostics.showDebugPanel"
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

    var body: some View {
        List {
            Section {
                Toggle("Show debug log panel", isOn: $showDebugPanel)
                    .onChange(of: showDebugPanel) { _, on in DebugLog.shared.enabled = on }
            } footer: {
                Text("Adds a 🐞 button in a connected session that opens a scrollable "
                     + "diagnostic log with a Copy button. For troubleshooting; leave off for normal use.")
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
                Text("Streams the verbose diagnostic trace off-device as RFC 5424 syslog. "
                     + "Receiver setup: see tools/syslog-sink (docker compose up). "
                     + "TLS uses a self-signed cert (verification off).")
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
        .navigationTitle("Diagnostics")
        .onAppear {
            DebugLog.shared.enabled = showDebugPanel
            rebuildSink()
            DebugLog.shared.refreshEnabledCategories()
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

    /// Recreate the sink from current config, or clear it when disabled/host empty.
    private func rebuildSink() {
        guard remoteEnabled, !remoteHost.isEmpty else { DebugLog.shared.setRemote(nil); return }
        DebugLog.shared.setRemote(RemoteLogSink(host: remoteHost, port: remotePort, transport: transport))
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
