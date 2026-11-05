// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

/// `KittyTransmissionFilter` (security audit L1): kitty graphics commands may not make
/// the app read its own files or shared memory.
final class KittyTransmissionFilterTests: XCTestCase {
    private func run(_ chunks: [String]) -> String {
        var f = KittyTransmissionFilter()
        return chunks.map { s -> String in
            var b = Array(s.utf8)
            f.filter(&b)
            return String(decoding: b, as: UTF8.self)
        }.joined()
    }

    private let esc = "\u{1B}"

    // Adversarial: each local-read transmission is rewritten to the unsupported `x`.
    func testFileTempAndSharedMemoryBlocked() {
        for mode in ["f", "t", "s"] {
            XCTAssertEqual(run(["\(esc)_Ga=T,t=\(mode),f=100;L2V0Yy9wYXNzd2Q=\(esc)\\"]),
                           "\(esc)_Ga=T,t=x,f=100;L2V0Yy9wYXNzd2Q=\(esc)\\", "mode \(mode)")
        }
    }

    // EP: inline data (`t=d`) and a command with no t key pass through unchanged.
    func testInlineTransmissionUntouched() {
        let inline = "\(esc)_Ga=T,t=d,f=100;iVBORw0KGgo=\(esc)\\"
        XCTAssertEqual(run([inline]), inline)
        let noKey = "\(esc)_Ga=T,f=100;iVBORw0KGgo=\(esc)\\"
        XCTAssertEqual(run([noKey]), noKey)
    }

    // `t` as the first key, right after G.
    func testFirstKeyBlocked() {
        XCTAssertEqual(run(["\(esc)_Gt=f;cGF0aA==\(esc)\\"]), "\(esc)_Gt=x;cGF0aA==\(esc)\\")
    }

    // Adversarial: a command split at every byte across reads is still caught.
    func testSplitAcrossEveryByte() {
        let cmd = "\(esc)_Ga=T,t=f;cGF0aA==\(esc)\\"
        XCTAssertEqual(run(cmd.map { String($0) }), "\(esc)_Ga=T,t=x;cGF0aA==\(esc)\\")
    }

    // Adversarial: a repeated t key is rewritten every time (the last one would win).
    func testRepeatedKeyAllBlocked() {
        XCTAssertEqual(run(["\(esc)_Gt=d,t=f;x\(esc)\\"]), "\(esc)_Gt=d,t=x;x\(esc)\\")
    }

    // The payload is never touched, even when it looks like `t=f`.
    func testPayloadNotRewritten() {
        let cmd = "\(esc)_Ga=T;t=f,t=s\(esc)\\"
        XCTAssertEqual(run([cmd]), cmd)
    }

    // Other keys whose value is f/t/s, or keys ending in t, are not the transmission.
    func testOtherKeysUntouched() {
        let cmd = "\(esc)_Ga=t,o=s,U=1;x\(esc)\\"
        XCTAssertEqual(run([cmd]), cmd)
    }

    // Plain text, CSI and OSC containing `t=f` are not kitty commands.
    func testNonKittyTextUntouched() {
        let text = "echo t=f; \(esc)[31mt=s\(esc)[0m \(esc)]0;_Gt=f\u{07} done"
        XCTAssertEqual(run([text]), text)
    }

    // A non-G APC is left alone.
    func testOtherApcUntouched() {
        let cmd = "\(esc)_Xt=f\(esc)\\"
        XCTAssertEqual(run([cmd]), cmd)
    }

    // A BEL-terminated command is closed; following text is ground again.
    func testBelTerminatorReturnsToGround() {
        XCTAssertEqual(run(["\(esc)_Gt=f;p\u{07}t=f"]), "\(esc)_Gt=x;p\u{07}t=f")
    }

    // Adversarial: the C1 APC introducer (0x9F) after an escape state, as SwiftTerm accepts it.
    func testC1ApcIntroducerBlocked() {
        var f = KittyTransmissionFilter()
        var b: [UInt8] = [0x1B, 0x9F] + Array("Gt=f;p".utf8) + [0x9C]
        f.filter(&b)
        XCTAssertEqual(b, [0x1B, 0x9F] + Array("Gt=x;p".utf8) + [0x9C])
    }

    // A raw 0x9F inside UTF-8 text in ground (an emoji) is printable, not an APC.
    func testEmojiInGroundNotApc() {
        let text = "\u{1F600}Gt=f"
        XCTAssertEqual(run([text]), text)
    }

    // BVA: byte count never changes, and an empty chunk is a no-op.
    func testLengthPreservedAndEmptyChunk() {
        var f = KittyTransmissionFilter()
        var empty: [UInt8] = []
        f.filter(&empty)
        XCTAssertEqual(empty, [])
        var b = Array("\(esc)_Ga=T,t=s;p\(esc)\\".utf8)
        let n = b.count
        f.filter(&b)
        XCTAssertEqual(b.count, n)
    }
}

final class KittyImageCacheLimitTests: XCTestCase {
    // L5: the cap is 64 MiB, well under SwiftTerm's 320 MB default.
    func testCacheLimitIs64MiB() {
        XCTAssertEqual(kittyImageCacheLimitBytes, 67_108_864)
    }
}
