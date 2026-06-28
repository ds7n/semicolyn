// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class FileBlobStoreTests: XCTestCase {
    private var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testPersistsAcrossInstances() throws {
        let id = UUID()
        try FileBlobStore(directory: dir).putBlob(Data([7, 8, 9]), type: "host", id: id)
        // Fresh instance, same directory — must read what the first wrote.
        let reread = try FileBlobStore(directory: dir).getBlob(type: "host", id: id)
        XCTAssertEqual(reread, Data([7, 8, 9]))
    }

    func testMissingReturnsNilAndListAndDelete() throws {
        let s = FileBlobStore(directory: dir)
        XCTAssertNil(try s.getBlob(type: "host", id: UUID()))
        let id = UUID()
        try s.putBlob(Data([1]), type: "host", id: id)
        XCTAssertEqual(try s.listBlobs(type: "host").map(\.id), [id])
        try s.deleteBlob(type: "host", id: id)
        XCTAssertNil(try s.getBlob(type: "host", id: id))
        try s.deleteBlob(type: "host", id: id)   // idempotent
    }

    func testListExcludesOtherTypesAndUnparseableFiles() throws {
        let s = FileBlobStore(directory: dir)
        let a = UUID(), b = UUID()
        try s.putBlob(Data([1]), type: "host", id: a)
        try s.putBlob(Data([2]), type: "defaults", id: b)
        XCTAssertEqual(try s.listBlobs(type: "host").map(\.id), [a])   // excludes "defaults"
        // A stray non-UUID file in the type dir must be skipped, not crash.
        let stray = dir.appendingPathComponent("host").appendingPathComponent("not-a-uuid.rec")
        try Data([0]).write(to: stray)
        XCTAssertEqual(try s.listBlobs(type: "host").map(\.id), [a])
    }
}
