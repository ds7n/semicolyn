// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
import SemicolynKit
@testable import SeedKit

final class TldrHoldoutTests: XCTestCase {
    func testHoldoutIsStableAndAboutTenPercent() {
        XCTAssertEqual(TldrHoldout.isHeldOut(pageStem: "git"), TldrHoldout.isHeldOut(pageStem: "git"))
        let stems = (0..<2000).map { "tool\($0)" }
        let held = stems.filter { TldrHoldout.isHeldOut(pageStem: $0) }.count
        XCTAssertTrue((150...250).contains(held), "held=\(held)")
    }

    /// FNV-1a 64 values computed independently (hash % 10): git=5, ls=8, tar=8, npm=0.
    func testKnownStems() {
        XCTAssertFalse(TldrHoldout.isHeldOut(pageStem: "git"))
        XCTAssertFalse(TldrHoldout.isHeldOut(pageStem: "ls"))
        XCTAssertFalse(TldrHoldout.isHeldOut(pageStem: "tar"))
        XCTAssertTrue(TldrHoldout.isHeldOut(pageStem: "npm"))
    }

    /// A held-out page (npm) adds nothing to a fair-baseline seed; a kept page (git) still does,
    /// and without the exclusion the held-out page is ingested as before.
    func testSeedInvocationsSkipHeldOutPage() {
        let npm = "# npm\n\n- Install:\n\n`npm install {{pkg}}`\n"
        let git = "# git\n\n- Status:\n\n`git status`\n"
        XCTAssertEqual(TldrHoldout.seedInvocations(pageStem: "npm", markdown: npm, excludingHeldOut: true), [])
        XCTAssertEqual(TldrHoldout.seedInvocations(pageStem: "git", markdown: git, excludingHeldOut: true),
                       [["git", "status"]])
        XCTAssertEqual(TldrHoldout.seedInvocations(pageStem: "npm", markdown: npm, excludingHeldOut: false),
                       [["npm", "install"]])

        var fair = SeedBuilder()
        for (stem, page) in [("npm", npm), ("git", git)] {
            for seq in TldrHoldout.seedInvocations(pageStem: stem, markdown: page, excludingHeldOut: true) {
                fair.ingest(seq)
            }
        }
        let uni = Vocabulary(deserializing: fair.blobs().unigram)
        XCTAssertEqual(uni?.candidates(forPrefix: "npm"), [])
        XCTAssertEqual(uni?.candidates(forPrefix: "ins"), [])
        XCTAssertEqual(uni?.candidates(forPrefix: "git"), [TokenCount(token: "git", count: 1)])
    }
}
