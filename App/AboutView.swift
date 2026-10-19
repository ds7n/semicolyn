// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import SemicolynKit

/// Settings → Help → About (M-75): version and build, Acknowledgements (Kit
/// `About.acknowledgements`, which mirrors the repo's licence files) and the
/// Source Code link (GPL-3.0).
struct AboutView: View {
    private var versionLabel: String {
        let info = Bundle.main.infoDictionary
        return About.versionLabel(version: info?["CFBundleShortVersionString"] as? String,
                                  build: info?["CFBundleVersion"] as? String)
    }

    var body: some View {
        List {
            Section {
                LabeledContent("semicolyn", value: versionLabel)
            }
            Section {
                NavigationLink("Acknowledgements") { AcknowledgementsView() }
                if let url = URL(string: About.sourceCodeURL) {
                    Link(destination: url) {
                        LabeledContent("Source Code", value: About.license)
                    }
                }
            } footer: {
                Text("semicolyn is free software under the GNU General Public License, version 3.")
            }
        }
        .navigationTitle("About")
    }
}

/// Every credited project, grouped, each pushing its licence details.
private struct AcknowledgementsView: View {
    var body: some View {
        List {
            ForEach(About.acknowledgements, id: \.header) { group in
                Section(group.header) {
                    ForEach(group.items, id: \.name) { item in
                        NavigationLink {
                            AcknowledgementDetailView(item: item)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name)
                                Text(item.licenseName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Acknowledgements")
    }
}

/// One project: what it's used for, licence, copyright, changes made and link. SCOWL
/// also shows its full bundled copyright notice.
private struct AcknowledgementDetailView: View {
    let item: Acknowledgement

    var body: some View {
        List {
            Section {
                LabeledContent("Used for", value: item.usedFor)
                LabeledContent("License", value: item.licenseName)
                Text(item.copyright)
                    .font(.callout)
                if let changes = item.changes {
                    Text("Changes: \(changes)")
                        .font(.callout)
                }
                if let url = URL(string: item.url) {
                    Link(item.url, destination: url)
                        .font(.callout)
                }
            }
            if item.name == "SCOWL", let notice = bundledText("SCOWL_COPYRIGHT", "txt") {
                Section("Copyright Notice") {
                    Text(notice)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle(item.name)
    }

    private func bundledText(_ name: String, _ ext: String) -> String? {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
