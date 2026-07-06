// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import UIKit

/// TEMPORARY on-screen diagnostic panel for the tmux reattach/no-echo investigation.
/// Toggled by a 🐞 button; shows the rolling `DebugLog` buffer, auto-scrolled to the
/// newest line, with Copy (→ clipboard, to paste back) and Clear. Remove with
/// `DebugLog` once the bug is root-caused.
struct DebugLogPanel: View {
    @ObservedObject var log = DebugLog.shared
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("debug log (\(log.lines.count))")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                Spacer()
                Button("Copy") { UIPasteboard.general.string = log.joined }
                    .font(.system(size: 11))
                Button("Clear") { log.clear() }
                    .font(.system(size: 11))
                Button("Close") { onClose() }
                    .font(.system(size: 11))
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Color.black.opacity(0.9))

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(log.lines.enumerated()), id: \.offset) { idx, line in
                            Text(line)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.green)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(idx)
                        }
                    }
                    .padding(.horizontal, 6)
                }
                .onChange(of: log.lines.count) { _, n in
                    if n > 0 { proxy.scrollTo(n - 1, anchor: .bottom) }
                }
            }
            .background(Color.black.opacity(0.85))
        }
        .frame(maxHeight: 320)
    }
}
