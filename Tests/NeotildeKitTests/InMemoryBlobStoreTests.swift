// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import NeotildeKit

final class InMemoryBlobStoreTests: XCTestCase {
    func testPutGetOverwriteDeleteAndList() throws {
        let s = InMemoryBlobStore()
        let a = UUID(), b = UUID()
        try s.putBlob(Data([1]), type: "host", id: a)
        try s.putBlob(Data([2]), type: "host", id: b)
        try s.putBlob(Data([9]), type: "defaults", id: a)
        XCTAssertEqual(try s.getBlob(type: "host", id: a), Data([1]))
        try s.putBlob(Data([3]), type: "host", id: a)                 // overwrite
        XCTAssertEqual(try s.getBlob(type: "host", id: a), Data([3]))
        XCTAssertNil(try s.getBlob(type: "host", id: UUID()))         // missing → nil
        XCTAssertEqual(Set(try s.listBlobs(type: "host").map(\.id)), [a, b])  // excludes "defaults"
        try s.deleteBlob(type: "host", id: a)
        XCTAssertNil(try s.getBlob(type: "host", id: a))
        try s.deleteBlob(type: "host", id: a)                        // idempotent, no throw
    }
}
