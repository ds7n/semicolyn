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

    @State private var testResult: String?
    @State private var showKeystrokeNag = false

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
                    if let testResult { Text(testResult).font(.footnote).foregroundStyle(.secondary) }
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
                        if on { keystrokeContent = false; showKeystrokeNag = true }  // require confirm
                    }
            } footer: {
                Text("Off: only structural key events (lengths, backspace) are logged. On: the "
                     + "actual keys are logged too — password/prompt lines are still redacted "
                     + "(shown as REDACTED, never dropped). Off by default.")
            }
        }
        .navigationTitle("Diagnostics")
        .onAppear { DebugLog.shared.enabled = showDebugPanel; rebuildSink() }
        .confirmationDialog("Log keystroke content?", isPresented: $showKeystrokeNag, titleVisibility: .visible) {
            Button("Turn On", role: .destructive) { keystrokeContent = true }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Diagnostic traces will include the actual keys you type, including anything "
                 + "sensitive, and stream to your configured host if remote logging is on. "
                 + "Password/prompt lines are still redacted.")
        }
    }

    /// Recreate the sink from current config, or clear it when disabled/host empty.
    private func rebuildSink() {
        guard remoteEnabled, !remoteHost.isEmpty else { DebugLog.shared.setRemote(nil); return }
        DebugLog.shared.setRemote(RemoteLogSink(host: remoteHost, port: remotePort, transport: transport))
    }

    private func runTest() {
        guard !remoteHost.isEmpty else { testResult = "Enter a host first."; return }
        testResult = "Testing…"
        let sink = RemoteLogSink(host: remoteHost, port: remotePort, transport: transport)
        sink.test { ok in
            DispatchQueue.main.async { testResult = ok ? "✓ Connected" : "✗ Failed" }
        }
    }
}
