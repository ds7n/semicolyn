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

    func testRecordRoundTripsThroughCodable() throws {
        let r = ResumableSession(sessionID: UUID(), hostID: UUID(), transport: .mosh,
                                 host: "server01.example.io", port: 60001,
                                 tmuxSessionName: "semicolyn", lastConnectedAt: Date(timeIntervalSince1970: 1_000))
        let data = try JSONEncoder().encode(r)
        let back = try JSONDecoder().decode(ResumableSession.self, from: data)
        XCTAssertEqual(back, r)
        XCTAssertEqual(back.transport, .mosh)
        XCTAssertNil(ResumableSession(sessionID: UUID(), hostID: UUID(), transport: .ssh,
                                      host: "h", port: 22, tmuxSessionName: nil,
                                      lastConnectedAt: Date(timeIntervalSince1970: 0)).tmuxSessionName)
    }
}
