// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// Custom-slot binding model: four bindable gestures, the ≥1-binding validity
/// rule, and the spec's primary-label resolution order
/// (explicit label → tap → first bound gesture). (keybar-customization spec
/// "Custom slot binding model" / "Slot display content".)
final class CustomSlotTests: XCTestCase {
    private let kc = MacroID("m-kc")
    private let up = MacroID("m-up")

    /// Resolver standing in for the library: macro id → display name.
    private func names(_ pairs: [MacroID: String]) -> (MacroID) -> String? {
        { pairs[$0] }
    }

    // MARK: - Gesture enum

    func testFourBindableGestures() {
        XCTAssertEqual(Set(CustomSlotGesture.allCases),
                       [.tap, .swipeUp, .swipeDown, .longPress])
    }

    // MARK: - Validity (≥1 binding)

    func testSlotWithNoBindingsIsInvalid() {
        let slot = CustomSlot(id: CustomSlotID("s1"), label: "x")
        XCTAssertFalse(slot.hasAnyBinding)
        XCTAssertFalse(slot.isValid)
    }

    func testSlotWithOnlySwipeUpIsValid() {
        let slot = CustomSlot(id: CustomSlotID("s1"), label: nil,
                              swipeUp: GestureBinding(macro: up))
        XCTAssertTrue(slot.hasAnyBinding)
        XCTAssertTrue(slot.isValid)
    }

    func testBindingAccessorReturnsTheBoundGesture() {
        let slot = CustomSlot(id: CustomSlotID("s1"), label: nil,
                              tap: GestureBinding(macro: kc))
        XCTAssertEqual(slot.binding(for: .tap)?.macro, kc)
        XCTAssertNil(slot.binding(for: .longPress))
    }

    // MARK: - Primary-label resolution

    func testExplicitLabelWins() {
        let slot = CustomSlot(id: CustomSlotID("s1"), label: "kc",
                              tap: GestureBinding(macro: kc))
        XCTAssertEqual(slot.displayLabel(macroName: names([kc: "kubectl"])), "kc")
    }

    func testFallsBackToTapMacroName() {
        let slot = CustomSlot(id: CustomSlotID("s1"), label: nil,
                              tap: GestureBinding(macro: kc))
        XCTAssertEqual(slot.displayLabel(macroName: names([kc: "kubectl"])), "kubectl")
    }

    func testBindingOverrideLabelPreferredOverMacroName() {
        let slot = CustomSlot(id: CustomSlotID("s1"), label: nil,
                              tap: GestureBinding(macro: kc, overrideLabel: "K8"))
        XCTAssertEqual(slot.displayLabel(macroName: names([kc: "kubectl"])), "K8")
    }

    func testTapUnboundFallsBackToFirstBoundGesture() {
        // tap unbound; swipeUp is the first bound gesture in display order.
        let slot = CustomSlot(id: CustomSlotID("s1"), label: nil,
                              swipeUp: GestureBinding(macro: up))
        XCTAssertEqual(slot.displayLabel(macroName: names([up: "scroll-up"])), "scroll-up")
    }

    func testEmptyExplicitLabelIsIgnored() {
        let slot = CustomSlot(id: CustomSlotID("s1"), label: "",
                              tap: GestureBinding(macro: kc))
        XCTAssertEqual(slot.displayLabel(macroName: names([kc: "kubectl"])), "kubectl")
    }

    func testNoBindingsAndNoLabelResolvesToNil() {
        let slot = CustomSlot(id: CustomSlotID("s1"), label: nil)
        XCTAssertNil(slot.displayLabel(macroName: names([:])))
    }

    // MARK: - Codable

    func testCustomSlotRoundTrips() throws {
        let slot = CustomSlot(
            id: CustomSlotID("s1"), label: "kc",
            tap: GestureBinding(macro: kc),
            swipeUp: GestureBinding(macro: up, overrideLabel: "↑"),
            longPress: GestureBinding(macro: kc))
        let data = try JSONEncoder().encode(slot)
        XCTAssertEqual(try JSONDecoder().decode(CustomSlot.self, from: data), slot)
    }
}
