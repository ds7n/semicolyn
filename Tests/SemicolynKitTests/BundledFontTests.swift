// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class BundledFontTests: XCTestCase {
    func testCatalogHasTwoBundledFonts() {
        XCTAssertEqual(FontCatalog.bundled.count, 2)
    }
    func testDefaultIsHackAndIsInCatalog() {
        XCTAssertEqual(FontCatalog.default.displayName, "Hack Nerd Font")
        XCTAssertTrue(FontCatalog.bundled.contains(FontCatalog.default),
                      "default must be a font we actually ship")
    }
    func testSettingsDefaultFaceIsHack() {
        XCTAssertEqual(TerminalSettings().fontFace, FontCatalog.default.face)
    }
    // resolve-with-fallback: EP over the 3 Kinds + the unknown-imported boundary.
    func testResolveSystemReturnsNilSentinel() {
        let face = TerminalFont(kind: .system, displayName: "System")
        XCTAssertNil(FontCatalog.resolvePostScriptName(face, registeredImported: []))
    }
    func testResolveBundledReturnsItsExactName() {
        let face = FontCatalog.default.face
        XCTAssertEqual(FontCatalog.resolvePostScriptName(face, registeredImported: []),
                       FontCatalog.default.postScriptName)
    }
    func testResolveKnownImportedReturnsItsExactName() {
        let face = TerminalFont(kind: .imported("MyFont-Regular"), displayName: "My Font")
        XCTAssertEqual(
            FontCatalog.resolvePostScriptName(face, registeredImported: ["MyFont-Regular"]),
            "MyFont-Regular")
    }
    func testResolveUnknownImportedFallsBackToDefaultName() {
        let face = TerminalFont(kind: .imported("Gone-Regular"), displayName: "Gone")
        XCTAssertEqual(
            FontCatalog.resolvePostScriptName(face, registeredImported: []),
            FontCatalog.default.postScriptName,   // specific fallback, not just non-nil
            "an unregistered imported face must fall back to the default, never tofu")
    }
}
