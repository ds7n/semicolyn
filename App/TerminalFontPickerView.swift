// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import UniformTypeIdentifiers
import SemicolynKit

/// Font-face picker: system + bundled Nerd Fonts, plus user-imported faces.
/// Each row previews sample letters and a couple of Nerd Font icons in that face.
struct TerminalFontPickerView: View {
    @EnvironmentObject private var store: TerminalSettingsStore
    @State private var importing = false
    @State private var importedFaces: [TerminalFont] = []

    private static let sample = "AaBb 0O ==> !=  \u{e0b0} \u{f07b} \u{f09b}"

    private var systemFace: TerminalFont { TerminalFont(kind: .system, displayName: "System") }

    var body: some View {
        List {
            Section("Bundled") {
                row(systemFace)
                ForEach(FontCatalog.bundled, id: \.postScriptName) { bf in
                    row(bf.face)
                }
            }
            Section("Imported") {
                ForEach(importedFaces, id: \.displayName) { face in
                    row(face)
                }
                .onDelete(perform: deleteImported)
                Button {
                    InputClickFeedback.play()
                    importing = true
                } label: {
                    Label("Import Font…", systemImage: "square.and.arrow.down")
                }
            }
        }
        .navigationTitle("Typeface")
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: [UTType(filenameExtension: "ttf"), UTType(filenameExtension: "otf")]
                .compactMap { $0 },
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
    }

    @ViewBuilder private func row(_ face: TerminalFont) -> some View {
        Button {
            InputClickFeedback.play()
            store.settings.fontFace = face
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(face.displayName)
                    Spacer()
                    if face == store.settings.fontFace {
                        Image(systemName: "checkmark").foregroundStyle(.tint)
                    }
                }
                Text(Self.sample)
                    .font(previewFont(for: face))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    private func previewFont(for face: TerminalFont) -> Font {
        Font(TerminalFontProvider.shared.font(for: face, size: 15))
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let src = urls.first else { return }
        guard let dest = copyIntoAppSupport(src) else { return }
        if let ps = TerminalFontProvider.shared.registerImported(fileURL: dest) {
            let face = TerminalFont(kind: .imported(ps),
                                    displayName: dest.deletingPathExtension().lastPathComponent)
            importedFaces.append(face)
            store.settings.fontFace = face
        }
    }

    private func copyIntoAppSupport(_ src: URL) -> URL? {
        let needsStop = src.startAccessingSecurityScopedResource()
        defer { if needsStop { src.stopAccessingSecurityScopedResource() } }
        guard let dir = TerminalFontProvider.ensureImportedFontsDirectory() else { return nil }
        let fm = FileManager.default
        let dest = dir.appendingPathComponent(src.lastPathComponent)
        try? fm.removeItem(at: dest)
        do {
            try fm.copyItem(at: src, to: dest)
            return dest
        } catch {
            return nil
        }
    }

    private func deleteImported(_ offsets: IndexSet) {
        for i in offsets {
            let face = importedFaces[i]
            if store.settings.fontFace == face {
                store.settings.fontFace = FontCatalog.default.face
            }
        }
        importedFaces.remove(atOffsets: offsets)
    }
}
