// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// Drag-ownership rules between the selection-handle drag, the content drag owners
/// (scroll / window-switch / alt-screen pans), the long-press and SwiftTerm's selection pan.
/// Device build 175: dragging a selection handle inside tmux ALSO switched windows, because
/// the handle drag had no rule against the alt-screen pan. These tests derive from the
/// exhaustive `isContentDragOwner` classification, so a drag owner added later inherits
/// every rule instead of silently shipping a gap.
final class GestureDragOwnershipTests: XCTestCase {
    private let owners = GestureRole.allCases.filter(\.isContentDragOwner)

    func testContentDragOwnersAreExactlyTheThreeContentPans() {
        XCTAssertEqual(Set(owners), [.scrollPan, .switchPan, .altScreenPan])
    }

    func testEveryDragOwnerIsExclusiveWithLongPressSelectionPanAndHandlePan() {
        for owner in owners {
            for rival: GestureRole in [.longPress, .selectionPan, .handlePan] {
                XCTAssertFalse(gesturesMayRecognizeSimultaneously(owner, rival), "\(owner) vs \(rival)")
                XCTAssertFalse(gesturesMayRecognizeSimultaneously(rival, owner), "\(rival) vs \(owner)")
            }
        }
    }

    /// The device bug: handle drag and the alt-screen pan (window swipe) on one touch.
    func testHandleDragNeverCoRecognizesWithAltScreenPan() {
        XCTAssertFalse(gesturesMayRecognizeSimultaneously(.handlePan, .altScreenPan))
    }

    /// A handle held still ~0.5s before dragging must not also fire the zoom long-press.
    func testHandleDragNeverCoRecognizesWithLongPress() {
        XCTAssertFalse(gesturesMayRecognizeSimultaneously(.handlePan, .longPress))
    }

    func testHandleDragCoexistsWithTapAndPinch() {
        XCTAssertTrue(gesturesMayRecognizeSimultaneously(.handlePan, .tap))
        XCTAssertTrue(gesturesMayRecognizeSimultaneously(.handlePan, .pinch))
    }

    /// Device build 176: making drag owners WAIT for the handle drag broke every swipe
    /// after a selection (the handle drag begins-then-cancels off a handle, which cancels
    /// its dependents). Ownership is decided at touch-down instead, so no owner ever waits.
    func testNoDragOwnerWaitsForTheHandleDrag() {
        for owner in owners {
            XCTAssertFalse(gestureMustWaitForFailure(owner, of: .handlePan), "\(owner)")
        }
    }

    func testTouchStartingOnAHandleIsClaimedOnlyByTheHandleDrag() {
        XCTAssertTrue(dragMayBegin(.handlePan, touchStartsOnHandle: true))
        for owner in owners {
            XCTAssertFalse(dragMayBegin(owner, touchStartsOnHandle: true), "\(owner)")
        }
    }

    func testTouchStartingOffAHandleIsClaimedOnlyByContentDragOwners() {
        XCTAssertFalse(dragMayBegin(.handlePan, touchStartsOnHandle: false))
        for owner in owners {
            XCTAssertTrue(dragMayBegin(owner, touchStartsOnHandle: false), "\(owner)")
        }
    }

    /// Recognizers that are neither the handle drag nor a content drag owner are not gated.
    func testOtherRolesAreNeverGatedByHandleOwnership() {
        for role in GestureRole.allCases where role != .handlePan && !role.isContentDragOwner {
            for onHandle in [true, false] {
                XCTAssertTrue(dragMayBegin(role, touchStartsOnHandle: onHandle), "\(role) onHandle=\(onHandle)")
            }
        }
    }

    func testSelectionPanWaitsForEveryDragOwner() {
        for owner in owners {
            XCTAssertTrue(gestureMustWaitForFailure(.selectionPan, of: owner), "\(owner)")
        }
    }

    /// Exhaustive: no pair outside the selection-pan rule above imposes a wait (an accidental wait
    /// stalls a recognizer; device build 117 lost native scrolling that way).
    func testNoOtherPairImposesAWait() {
        for g in GestureRole.allCases {
            for other in GestureRole.allCases {
                if g == .selectionPan && other.isContentDragOwner { continue }
                XCTAssertFalse(gestureMustWaitForFailure(g, of: other), "\(g) waits on \(other)")
            }
        }
    }
}
