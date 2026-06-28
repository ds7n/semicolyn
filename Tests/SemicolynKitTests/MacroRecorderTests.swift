// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// `MacroRecorder` — the pure accumulation model behind record mode: captures
/// input events in order, then lets the review UI reorder / delete / insert
/// chips before saving (keybar-customization spec "Record mode").
final class MacroRecorderTests: XCTestCase {
    func testStartsEmpty() {
        let rec = MacroRecorder()
        XCTAssertTrue(rec.isEmpty)
        XCTAssertEqual(rec.events, [])
    }

    func testRecordAppendsInOrder() {
        var rec = MacroRecorder()
        rec.record(MacroEvent(key: .char("l")))
        rec.record(MacroEvent(key: .char("s")))
        rec.record(MacroEvent(key: .enter))
        XCTAssertFalse(rec.isEmpty)
        XCTAssertEqual(rec.events.map(\.key), [.char("l"), .char("s"), .enter])
    }

    func testRemoveAtIndexDropsThatChip() {
        var rec = MacroRecorder(events: [
            MacroEvent(key: .char("a")), MacroEvent(key: .char("b")), MacroEvent(key: .char("c")),
        ])
        rec.removeEvent(at: 1)
        XCTAssertEqual(rec.events.map(\.key), [.char("a"), .char("c")])
    }

    func testRemoveAtOutOfRangeIndexIsIgnored() {
        var rec = MacroRecorder(events: [MacroEvent(key: .char("a"))])
        rec.removeEvent(at: 5)
        XCTAssertEqual(rec.events.map(\.key), [.char("a")])
    }

    func testInsertPlacesChipAtIndex() {
        var rec = MacroRecorder(events: [MacroEvent(key: .char("a")), MacroEvent(key: .char("c"))])
        rec.insertEvent(MacroEvent(key: .char("b")), at: 1)
        XCTAssertEqual(rec.events.map(\.key), [.char("a"), .char("b"), .char("c")])
    }

    func testMoveReordersChip() {
        var rec = MacroRecorder(events: [
            MacroEvent(key: .char("a")), MacroEvent(key: .char("b")), MacroEvent(key: .char("c")),
        ])
        rec.moveEvent(from: 0, to: 2)   // a → after b
        XCTAssertEqual(rec.events.map(\.key), [.char("b"), .char("a"), .char("c")])
    }

    func testMakeMacroBundlesRecordedEventsUnderIdAndName() {
        var rec = MacroRecorder()
        rec.record(MacroEvent(key: .char("k")))
        let macro = rec.makeMacro(id: MacroID("m1"), name: "K")
        XCTAssertEqual(macro, Macro(id: MacroID("m1"), name: "K",
                                    body: [MacroEvent(key: .char("k"))]))
    }
}
