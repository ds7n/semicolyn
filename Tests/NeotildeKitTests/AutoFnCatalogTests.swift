// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import NeotildeKit

final class AutoFnCatalogTests: XCTestCase {
    func testBundledIsExactlyHtopTopMc() {
        XCTAssertEqual(AutoFnCatalog.bundled, ["htop", "top", "mc"])
        // Deliberately excluded editors:
        XCTAssertFalse(AutoFnCatalog.bundled.contains("vim"))
        XCTAssertFalse(AutoFnCatalog.bundled.contains("nano"))
    }

    func testNilOverrideReturnsBundledNoWarning() {
        let (procs, warning) = AutoFnCatalog.load(userOverrideJSON: nil)
        XCTAssertEqual(procs, AutoFnCatalog.bundled)
        XCTAssertNil(warning)
    }

    func testValidOverrideUnionsBundled() {
        let json = Data("""
        { "btop": { "autoFn": true }, "top": { "autoFn": false } }
        """.utf8)
        let (procs, warning) = AutoFnCatalog.load(userOverrideJSON: json)
        XCTAssertNil(warning)
        XCTAssertTrue(procs.contains("btop"))   // user-added
        XCTAssertTrue(procs.contains("htop"))   // bundled retained
        XCTAssertFalse(procs.contains("top"))   // user disabled
    }

    func testMalformedOverrideFallsBackWithWarning() {
        let (procs, warning) = AutoFnCatalog.load(userOverrideJSON: Data("{ bad".utf8))
        XCTAssertEqual(procs, AutoFnCatalog.bundled)
        XCTAssertEqual(warning, "Auto-Fn override file is invalid — using defaults.")
    }
}
