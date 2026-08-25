// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class ResumableSessionStoreTests: XCTestCase {
    func testStorageSeamsExist() {
        XCTAssertEqual(RecordType.resumableSession.rawValue, "resumableSession")
        let id = UUID()
        XCTAssertEqual(SecretRef.resumeSecret(sessionID: id), SecretRef.resumeSecret(sessionID: id))
    }
}
