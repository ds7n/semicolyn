// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import UniformTypeIdentifiers
import SemicolynKit

/// Font-face picker: system + bundled Nerd Fonts, plus user-imported faces (listed
/// from the imported-fonts folder every time, so they survive reopening the screen).
/// Each row previews sample letters and a couple of Nerd Font icons in that face.
struct TerminalFontPickerView: View {
    // Direct singleton read, not `@EnvironmentObject` (which crashes if uninjected). This
    // picker is pushed from AppearanceSettingsView, which is reached via a Settings sheet
    // that does not propagate the app-root injection. See TerminalSettingsView.
    @ObservedObject private var store = AppStores.shared.terminalSettings
    @State private var importing = false
    /// The imported font files, refreshed from `TerminalFontProvider` on appear and
    /// after every import or delete.
    @State private var importedFiles: [TerminalFontProvider.ImportedFontFile] = []
    /// Deleting the face in use asks first (the terminal falls back to the default).
    @State private var pendingActiveDelete: TerminalFontProvider.ImportedFontFile?

    private static let sample = "AaBb 0O ==> !=  \u{e0b0} \u{f07b} \u{f09b}"

    private var systemFace: TerminalFont { TerminalFont(kind: .system, displayName: "System") }

    var body: some View {
        List {
            Section {
                row(systemFace)
                ForEach(FontCatalog.bundled, id: \.postScriptName) { bf in
                    row(bf.face)
                }
            } header: {
                Text("Bundled")
            } footer: {
                Text("Nerd Fonts include extra icons that some command-line tools use.")
            }
            Section {
                ForEach(importedFiles, id: \.self) { file in
                    row(file.face)
                }
                .onDelete(perform: deleteImported)
                Button {
                    InputClickFeedback.play()
                    importing = true
                } label: {
                    Label("Import Font…", systemImage: "square.and.arrow.down")
                }
            } header: {
                Text("Imported")
            } footer: {
                Text("Fonts you import (.ttf, .otf) appear here.")
            }
        }
        .navigationTitle("Typeface")
        .onAppear { importedFiles = TerminalFontProvider.shared.importedFiles }
        .confirmationDialog(
            "Delete “\(pendingActiveDelete?.face.displayName ?? "")”?",
            isPresented: Binding(get: { pendingActiveDelete != nil },
                                 set: { if !$0 { pendingActiveDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingActiveDelete
        ) { file in
            Button("Delete", role: .destructive) { remove(file); pendingActiveDelete = nil }
            Button("Cancel", role: .cancel) { pendingActiveDelete = nil }
        } message: { _ in
            Text("It's the typeface in use. The terminal switches to \(FontCatalog.default.face.displayName).")
        }
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
        if TerminalFontProvider.shared.registerImported(fileURL: dest) != nil {
            importedFiles = TerminalFontProvider.shared.importedFiles
            if let file = importedFiles.first(where: { $0.url == dest }) {
                store.settings.fontFace = file.face
            }
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

    /// Swipe-delete: removes the file and unregisters it. The face in use asks first.
    private func deleteImported(_ offsets: IndexSet) {
        for file in offsets.map({ importedFiles[$0] }) {
            if store.settings.fontFace == file.face {
                pendingActiveDelete = file
            } else {
                remove(file)
            }
        }
    }

    private func remove(_ file: TerminalFontProvider.ImportedFontFile) {
        if store.settings.fontFace == file.face {
            store.settings.fontFace = FontCatalog.default.face
        }
        TerminalFontProvider.shared.removeImported(file)
        importedFiles = TerminalFontProvider.shared.importedFiles
    }
}
