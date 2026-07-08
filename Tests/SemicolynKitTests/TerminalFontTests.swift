// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class TerminalFontTests: XCTestCase {
    // Round-trip each Kind case (EP over the 3 partitions).
    func testCodableRoundTripSystem() throws {
        let f = TerminalFont(kind: .system, displayName: "System")
        let back = try JSONDecoder().decode(TerminalFont.self, from: JSONEncoder().encode(f))
        XCTAssertEqual(back, f)
    }
    func testCodableRoundTripBundled() throws {
        let f = TerminalFont(kind: .bundled("HackNerdFont-Regular"), displayName: "Hack Nerd Font")
        let back = try JSONDecoder().decode(TerminalFont.self, from: JSONEncoder().encode(f))
        XCTAssertEqual(back, f)
    }
    func testCodableRoundTripImported() throws {
        let f = TerminalFont(kind: .imported("MyFont-Regular"), displayName: "My Font")
        let back = try JSONDecoder().decode(TerminalFont.self, from: JSONEncoder().encode(f))
        XCTAssertEqual(back, f)
    }

    func testTerminalSettingsCodableRoundTrip() throws {
        var s = TerminalSettings(fontSize: 15, cursorStyle: .bar, cursorBlink: true, scrollbackLines: 2000)
        s.fontFace = TerminalFont(kind: .bundled("HackNerdFont-Regular"), displayName: "Hack Nerd Font")
        let back = try JSONDecoder().decode(TerminalSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
    }

    // Hashable: distinct faces are distinct Set members; equal faces collapse. This is
    // what the picker's `ForEach(..., id: \.self)` relies on for correct row identity —
    // two imported fonts differing only by PostScript name must NOT collide even when
    // their displayName is identical (the same-basename-import bug the picker guards).
    func testTerminalFontHashableDistinguishesSameDisplayNameDifferentKind() {
        let a = TerminalFont(kind: .imported("FontA-Regular"), displayName: "MyFont")
        let b = TerminalFont(kind: .imported("FontB-Regular"), displayName: "MyFont")
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(Set([a, b, a]).count, 2)   // a de-dupes with itself; b stays distinct
    }
    func testTerminalFontHashableEqualFacesCollapseInSet() {
        let x = TerminalFont(kind: .bundled("HackNF-Regular"), displayName: "Hack Nerd Font")
        let y = TerminalFont(kind: .bundled("HackNF-Regular"), displayName: "Hack Nerd Font")
        XCTAssertEqual(x, y)
        XCTAssertEqual(Set([x, y]).count, 1)
    }
}
