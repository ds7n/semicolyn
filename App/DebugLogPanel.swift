// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import UIKit
import SemicolynKit

/// On-screen diagnostic panel (Settings → Diagnostics). Shows the rolling `DebugLog`
/// buffer with Copy and Clear. Copy (privacy audit P-M4 D) is a menu: a tap copies the
/// shareable text (typed keys, hosts, users and server text replaced); "Copy Full" copies
/// everything after Face ID / passcode. The buffer is not `@Published` (so
/// recording never invalidates SwiftUI per keystroke); the panel instead observes
/// `log.revision` and drives `refresh()` on a ~0.5s timer while visible, a redraw
/// cadence the human eye can't out-pace, at zero cost to the input path.
struct DebugLogPanel: View {
    @ObservedObject var log = DebugLog.shared
    let onClose: () -> Void

    /// Refresh the panel a couple of times a second while it is open.
    private let tick = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("debug log (\(log.lines.count))")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                Spacer()
                Menu {
                    Button("Copy (shareable)") { copyShareable() }
                    Button("Copy Full (includes typed keys)") { Task { await copyFull() } }
                } label: {
                    Text("Copy")
                } primaryAction: {
                    copyShareable()
                }
                .font(.system(size: 11))
                Button("Clear") { InputClickFeedback.play(); log.clear() }
                    .font(.system(size: 11))
                Button("Close") { InputClickFeedback.play(); onClose() }
                    .font(.system(size: 11))
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Color.black.opacity(0.9))

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(log.lines.enumerated()), id: \.offset) { idx, line in
                            Text(renderLogLine(line.line, .full))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.green)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(idx)
                        }
                    }
                    .padding(.horizontal, 6)
                    .id(log.revision)   // redraw when refresh() bumps revision
                }
                .onChange(of: log.revision) { _, _ in
                    if !log.lines.isEmpty { proxy.scrollTo(log.lines.count - 1, anchor: .bottom) }
                }
            }
            .background(Color.black.opacity(0.85))
        }
        .frame(maxHeight: 320)
        .onReceive(tick) { _ in log.refresh() }
    }

    private func copyShareable() {
        InputClickFeedback.play()
        copyToClipboard(log.shareableText, source: .app)
    }

    /// Face ID / passcode, then copy everything. No passcode on the device means nothing
    /// to verify against, as for the other owner checks; a cancel copies nothing.
    private func copyFull() async {
        InputClickFeedback.play()
        do {
            try await KeyAccessAuthorizer.shared.verifyOwner(identityName: "the full debug log",
                                                             reason: "Copy the full debug log")
        } catch KeyAccessError.unavailable {
            // No passcode set: proceed.
        } catch {
            DebugLog.shared.log(.lifecycle, "diagnostics: copy full refused (\(error))")
            return
        }
        copyToClipboard(log.fullText, source: .app)
    }
}
