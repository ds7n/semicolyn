// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import SemicolynKit

final class MoshLocaleTests: XCTestCase {
    // A well-formed user locale comes first, then the two fallbacks in order.
    func testUserLocaleFirstThenFallbacks() {
        XCTAssertEqual(moshLocaleCandidates(languageCode: "fr", regionCode: "FR"),
                       ["fr_FR.UTF-8", "C.UTF-8", "en_US.UTF-8"])
    }

    // Case is normalized to the POSIX form (language lower, region upper).
    func testCaseNormalized() {
        XCTAssertEqual(moshLocaleCandidates(languageCode: "DE", regionCode: "at").first, "de_AT.UTF-8")
    }

    // A US English user isn't offered en_US twice.
    func testUSEnglishNotDuplicated() {
        XCTAssertEqual(moshLocaleCandidates(languageCode: "en", regionCode: "US"),
                       ["en_US.UTF-8", "C.UTF-8"])
    }

    // BVA on the language length: 2 and 3 letters pass, 1 and 4 are skipped.
    func testLanguageLengthBoundaries() {
        XCTAssertEqual(moshLocaleCandidates(languageCode: "fil", regionCode: "PH").first, "fil_PH.UTF-8")
        XCTAssertEqual(moshLocaleCandidates(languageCode: "f", regionCode: "PH"), ["C.UTF-8", "en_US.UTF-8"])
        XCTAssertEqual(moshLocaleCandidates(languageCode: "filx", regionCode: "PH"), ["C.UTF-8", "en_US.UTF-8"])
    }

    // A missing part, a numeric region (es_419) or a 3-letter region is skipped, not guessed.
    func testMalformedRegionsSkipped() {
        let fallbacks = ["C.UTF-8", "en_US.UTF-8"]
        XCTAssertEqual(moshLocaleCandidates(languageCode: nil, regionCode: "FR"), fallbacks)
        XCTAssertEqual(moshLocaleCandidates(languageCode: "fr", regionCode: nil), fallbacks)
        XCTAssertEqual(moshLocaleCandidates(languageCode: "es", regionCode: "419"), fallbacks)
        XCTAssertEqual(moshLocaleCandidates(languageCode: "fr", regionCode: "FRA"), fallbacks)
    }

    // Adversarial: shell metacharacters or non-ASCII letters never reach the candidate list.
    func testInjectionAndNonASCIIRejected() {
        let fallbacks = ["C.UTF-8", "en_US.UTF-8"]
        XCTAssertEqual(moshLocaleCandidates(languageCode: "e;", regionCode: "US"), fallbacks)
        XCTAssertEqual(moshLocaleCandidates(languageCode: "en", regionCode: "U$"), fallbacks)
        XCTAssertEqual(moshLocaleCandidates(languageCode: "én", regionCode: "US"), fallbacks)
    }

    // The retry signal is mosh-server's specific refusal, nothing else.
    func testRetryOnlyOnLocaleRefusal() {
        XCTAssertTrue(moshNeedsLocaleRetry("mosh-server needs a UTF-8 native locale to run.\n"))
        XCTAssertFalse(moshNeedsLocaleRetry("\r\nMOSH CONNECT 60001 abcdefghijklmnopqrstuv\r\n"))
        XCTAssertFalse(moshNeedsLocaleRetry("bash: mosh-server: command not found"))
    }

    // Adversarial: an unexpected locale string is shell-quoted into one word in the argv.
    func testServerCommandQuotesLocale() {
        let argv = moshServerCommand(MoshConfig(enabled: true), locale: "x;id")
        XCTAssertEqual(argv[7], "'LANG=x;id'")
    }
}
