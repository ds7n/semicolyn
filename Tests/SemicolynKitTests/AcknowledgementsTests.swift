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

    /// Drift guard: every licensed source heading in the bundled SEED_ATTRIBUTION.md
    /// ("## <name> (<who>): <SPDX>") has an entry with the same licence.
    func testEveryPredictorAttributionHeadingIsCredited() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: repo.appendingPathComponent("App/Resources/predictor/SEED_ATTRIBUTION.md"),
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
