// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import UIKit
import CoreText
import SemicolynKit

/// Registers bundled + imported Nerd Fonts with CoreText and resolves a
/// `TerminalFont` to a concrete `UIFont`. The resolver always returns a real
/// font — an unresolvable name falls back through the Kit default to the
/// system monospace, never tofu.
@MainActor final class TerminalFontProvider {
    static let shared = TerminalFontProvider()

    private(set) var registeredImportedNames: Set<String> = []
    private var didRegisterBundled = false

    /// Register the curated bundled fonts. Idempotent; safe to call at launch.
    func registerBundledFonts() {
        guard !didRegisterBundled else { return }
        didRegisterBundled = true
        for f in FontCatalog.bundled {
            guard let url = Bundle.main.url(forResource: f.fileName, withExtension: "ttf")
                ?? Bundle.main.url(forResource: f.fileName, withExtension: "otf") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    /// Register a user-imported font file. Returns its PostScript name on success.
    func registerImported(fileURL: URL) -> String? {
        guard CTFontManagerRegisterFontsForURL(fileURL as CFURL, .process, nil) else { return nil }
        guard let data = try? Data(contentsOf: fileURL),
              let provider = CGDataProvider(data: data as CFData),
              let cg = CGFont(provider),
              let ps = cg.postScriptName as String? else { return nil }
        registeredImportedNames.insert(ps)
        return ps
    }

    /// Resolve a face to a concrete UIFont. Never returns a tofu font.
    func font(for face: TerminalFont, size: CGFloat) -> UIFont {
        guard let name = FontCatalog.resolvePostScriptName(
            face, registeredImported: registeredImportedNames) else {
            return .monospacedSystemFont(ofSize: size, weight: .regular)
        }
        if let font = UIFont(name: name, size: size) { return font }
        // name resolved by Kit but not actually available → default, then system.
        if let def = UIFont(name: FontCatalog.default.postScriptName, size: size) { return def }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }
}
