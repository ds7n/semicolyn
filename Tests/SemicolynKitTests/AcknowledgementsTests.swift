// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
import Foundation
@testable import SemicolynKit

/// M-75: About (version label, source link) and the Acknowledgements list.
final class AcknowledgementsTests: XCTestCase {
    private var all: [Acknowledgement] { About.acknowledgements.flatMap(\.items) }

    func testVersionLabel() {
        XCTAssertEqual(About.versionLabel(version: "0.1.0", build: "42"), "Version 0.1.0 (42)")
        XCTAssertEqual(About.versionLabel(version: "0.1.0", build: nil), "Version 0.1.0")
        XCTAssertEqual(About.versionLabel(version: "0.1.0", build: " "), "Version 0.1.0")
        XCTAssertEqual(About.versionLabel(version: nil, build: "7"), "Version Unknown (7)")
        XCTAssertEqual(About.versionLabel(version: "", build: nil), "Version Unknown")
    }

    func testSourceCodeLinkAndLicense() {
        XCTAssertEqual(About.sourceCodeURL, "https://github.com/ds7n/semicolyn")
        XCTAssertEqual(About.license, "GPL-3.0")
    }

    func testCreditsTheVendoredLibrariesAndFonts() {
        let names = Set(all.map(\.name))
        for required in ["SwiftTerm", "Mosh", "Eternal Terminal", "russh", "Nerd Fonts", "SCOWL",
                         "Hack", "JetBrains Mono", "tldr-pages", "Fig autocomplete", "wordfreq",
                         "Google Books Ngram Viewer", "Wikipedia page titles", "words/cuss"] {
            XCTAssertTrue(names.contains(required), required)
        }
        XCTAssertEqual(names.count, all.count, "duplicate acknowledgement names")
    }

    /// CC BY and CC BY-SA require attribution, a licence link and a note of changes.
    func testCreativeCommonsSourcesSayWhatChanged() {
        let cc = all.filter { $0.spdx.hasPrefix("CC-") }
        XCTAssertEqual(Set(cc.map(\.name)),
                       ["Google Books Ngram Viewer", "wordfreq", "Wikipedia page titles", "tldr-pages"])
        for item in cc {
            XCTAssertFalse(item.changes?.isEmpty ?? true, item.name)
        }
        XCTAssertEqual(cc.first { $0.name == "wordfreq" }?.licenseName, "CC BY-SA 4.0")
        XCTAssertEqual(cc.first { $0.name == "tldr-pages" }?.licenseName, "CC BY 4.0")
        XCTAssertEqual(cc.first { $0.name == "Google Books Ngram Viewer" }?.licenseName, "CC BY 3.0")
    }

    func testEveryEntryHasAWebLinkAndCopyright() {
        for item in all {
            let url = URL(string: item.url)
            XCTAssertTrue(["https", "http"].contains(url?.scheme ?? ""), item.name)
            XCTAssertFalse(url?.host?.isEmpty ?? true, item.name)
            XCTAssertFalse(item.copyright.isEmpty, item.name)
            XCTAssertFalse(item.usedFor.isEmpty, item.name)
        }
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Every file under App/Resources by bare name. XcodeGen copies resources flat into
    /// the bundle, so a name used twice would shadow the other.
    private func bundledResourceNames() throws -> [String: [String]] {
        let resources = repoRoot.appendingPathComponent("App/Resources")
        guard let walker = FileManager.default.enumerator(at: resources, includingPropertiesForKeys: nil) else {
            XCTFail("cannot list \(resources.path)")
            return [:]
        }
        var names: [String: [String]] = [:]
        for case let url as URL in walker where !url.hasDirectoryPath {
            names[url.lastPathComponent, default: []].append(url.path)
        }
        return names
    }

    /// Licences that require their text to ship (MIT, BSD, ISC, zlib, Apache 4(a), OFL,
    /// GPL, Mosh's COPYING.iOS): every entry, and semicolyn itself, names at least one
    /// bundled licence file, and each named file exists exactly once under App/Resources.
    func testEveryAcknowledgementShipsItsLicenceText() throws {
        let names = try bundledResourceNames()
        XCTAssertGreaterThan(names.count, 40, "App/Resources not found at \(repoRoot.path)")
        for item in all {
            XCTAssertFalse(item.licenseFiles.isEmpty, "\(item.name) lists no licence file")
            for file in item.licenseFiles {
                XCTAssertEqual(names[file]?.count, 1, "\(item.name): \(file) must exist once under App/Resources")
            }
        }
        XCTAssertEqual(About.licenseFiles, ["GPL-3.0.txt", "semicolyn-App-Store-exception.txt"])
        for file in About.licenseFiles {
            XCTAssertEqual(names[file]?.count, 1, "semicolyn: \(file) must exist once under App/Resources")
        }
    }

    /// The bundled texts are the real ones, not placeholders: spot-check the licences the
    /// audit called out (Mosh's App Store notice, GPL v3, the Rust crate document).
    func testLicenceTextsHaveTheirRequiredContent() throws {
        let dir = repoRoot.appendingPathComponent("App/Resources/Licenses")
        func text(_ name: String) throws -> String {
            try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
        }
        XCTAssertTrue(try text("GPL-3.0.txt").hasPrefix("                    GNU GENERAL PUBLIC LICENSE\n                       Version 3, 29 June 2007"))
        XCTAssertTrue(try text("Mosh-COPYING.iOS.txt").contains("we will\nnot object to your distribution of Mosh through the App Store."))
        let rust = try text("Rust-libraries.txt")
        XCTAssertTrue(rust.contains("\nrussh 0.61.2: Apache-2.0\n"), "russh missing from the Rust crate list")
        XCTAssertTrue(rust.contains("\nbytes 1.12.0: MIT\n"), "MIT-only crate missing from the Rust crate list")
        XCTAssertFalse(rust.contains("semicolyn-ssh-core 0.1.0:"), "our own crate is credited as semicolyn, not here")
    }

    /// Drift guard: every licensed source heading in the bundled SEED_ATTRIBUTION.md
    /// ("## <name> (<who>): <SPDX>") has an entry with the same licence.
    func testEveryPredictorAttributionHeadingIsCredited() throws {
        let text = try String(contentsOf: repoRoot.appendingPathComponent("App/Resources/predictor/SEED_ATTRIBUTION.md"),
                              encoding: .utf8)
        let headings = text.split(separator: "\n").filter { $0.hasPrefix("## ") && $0.contains("): ") }
        XCTAssertGreaterThanOrEqual(headings.count, 7)
        for heading in headings {
            let body = heading.dropFirst(3)
            let name = String(body[..<body.range(of: " (")!.lowerBound])
            let license = String(body[body.range(of: "): ")!.upperBound...])
            let match = all.first { name.hasPrefix($0.name) || $0.name.hasPrefix(name) }
            XCTAssertNotNil(match, "no acknowledgement for \(name)")
            if license.contains(" ") { continue }   // prose ("SCOWL copyright notice"), not an SPDX id
            XCTAssertEqual(match?.spdx, license, name)
        }
    }
}
