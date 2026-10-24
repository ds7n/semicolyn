// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import SemicolynKit

/// Settings → Help → About (M-75): version and build, Acknowledgements (Kit
/// `About.acknowledgements`, which mirrors the repo's licence files), semicolyn's own
/// licence text and the Source Code link (GPL-3.0).
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
                NavigationLink("License") { SemicolynLicenseView() }
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

/// One project: what it's used for, licence, copyright, changes made and link, then the
/// full text of every bundled licence file it names (`Acknowledgement.licenseFiles`).
private struct AcknowledgementDetailView: View {
    let item: Acknowledgement
    @State private var licenses: [BundledLicense] = []

    var body: some View {
        List {
            Section {
                LabeledContent("Used for", value: item.usedFor)
                LabeledContent("License", value: item.licenseName)
                Text(item.copyright)
                    .font(.callout)
                    .textSelection(.enabled)
                if let changes = item.changes {
                    Text("Changes: \(changes)")
                        .font(.callout)
                }
                if let url = URL(string: item.url) {
                    Link(item.url, destination: url)
                        .font(.callout)
                }
            }
            LicenseTextSections(licenses: licenses)
        }
        .navigationTitle(item.name)
        .task { licenses = BundledLicense.load(item.licenseFiles) }
    }
}

/// semicolyn's own licence: the GNU GPL v3 and the App Store permission.
private struct SemicolynLicenseView: View {
    @State private var licenses: [BundledLicense] = []

    var body: some View {
        List {
            LicenseTextSections(licenses: licenses)
        }
        .navigationTitle("License")
        .task { licenses = BundledLicense.load(About.licenseFiles) }
    }
}

/// One bundled licence file, split at blank lines so a long document (the Rust crate
/// list runs to thousands of lines) renders lazily, one List row per paragraph.
private struct BundledLicense: Identifiable {
    let file: String
    /// nil when the file is missing from the bundle.
    let paragraphs: [String]?
    var id: String { file }

    /// Reads each named file from the app bundle (resources are copied flat).
    static func load(_ files: [String]) -> [BundledLicense] {
        files.map { file in
            guard let url = Bundle.main.url(forResource: file, withExtension: nil),
                  let text = try? String(contentsOf: url, encoding: .utf8) else {
                return BundledLicense(file: file, paragraphs: nil)
            }
            let paragraphs = text.components(separatedBy: "\n\n")
                .map { $0.trimmingCharacters(in: .newlines) }
                .filter { !$0.isEmpty }
            return BundledLicense(file: file, paragraphs: paragraphs)
        }
    }
}

/// A section per licence file showing its full text, monospaced and selectable.
private struct LicenseTextSections: View {
    let licenses: [BundledLicense]

    var body: some View {
        ForEach(licenses) { license in
            Section {
                if let paragraphs = license.paragraphs {
                    ForEach(paragraphs.indices, id: \.self) { index in
                        Text(paragraphs[index])
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .listRowSeparator(.hidden)
                    }
                } else {
                    Text("This license text is missing from the app.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(license.file)
                    .textCase(nil)
            }
        }
    }
}
