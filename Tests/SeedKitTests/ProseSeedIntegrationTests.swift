// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
import Foundation
@testable import SemicolynKit

/// Integration test over the SHIPPED seeds (seed_v1.sketch + prose_en_v1.sketch):
/// asserts the tuned behavior end to end, context shifts CLI-vs-prose suggestions,
/// and NO blocklisted token ever leaks into a suggestion. Locks the Task-7 tuning.
final class ProseSeedIntegrationTests: XCTestCase {
    private func loadSeed(_ name: String) -> PredictorSeed? {
        let here = URL(fileURLWithPath: #filePath)
        let repo = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = repo.appendingPathComponent("App/Resources/predictor/\(name).sketch")
        guard let data = try? Data(contentsOf: url),
              let bundled = BundledSeed(combinedBlob: [UInt8](data)),
              let uni = Vocabulary(deserializing: bundled.unigramBlob),
              let bi = BigramVocabulary(deserializing: bundled.bigramBlob) else { return nil }
        return PredictorSeed(unigram: uni, bigram: bi)
    }

    private func blocklist() -> Set<String> {
        let here = URL(fileURLWithPath: #filePath)
        let repo = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = repo.appendingPathComponent("App/Resources/predictor/profanity_blocklist.txt")
        return Set((try? String(contentsOf: url, encoding: .utf8))?
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() } ?? [])
    }

    private func makeEngine() throws -> PredictorEngine {
        guard let prose = loadSeed("prose_en_v1"), let cli = loadSeed("seed_v1") else {
            throw XCTSkip("shipped seeds not present")
        }
        let filter = TokenFilter(patterns: TokenFilter.defaultPatterns + [.blocklist(blocklist())])
        return PredictorEngine(learned: .empty, seed: cli, proseSeed: prose, filter: filter)
    }

    /// Context must shift the register: a CLI context surfaces commands, a prose
    /// context surfaces prose words, for prefixes where the two domains diverge.
    func testContextShiftsRegister() throws {
        let engine = try makeEngine()
        func suggest(_ prefix: String, _ process: String) -> [String] {
            engine.suggestions(forPrefix: prefix, after: nil,
                               context: PredictionContext(foregroundProcess: process))
        }
        // "re": CLI -> remove/restore/restart ; prose -> request/response/refactor.
        let reCli = suggest("re", "zsh")
        let reProse = suggest("re", "claude")
        XCTAssertNotEqual(reCli, reProse, "context should change 're' suggestions")
        XCTAssertTrue(reCli.contains("remove"), "zsh 're' should surface the command 'remove'; got \(reCli)")
        XCTAssertTrue(reProse.contains("request") || reProse.contains("response"),
                      "claude 're' should surface prose; got \(reProse)")

        // "co": CLI -> config/completion ; prose -> could/connection/convert.
        let coProse = suggest("co", "claude")
        XCTAssertTrue(coProse.contains("could") || coProse.contains("convert") || coProse.contains("connection"),
                      "claude 'co' should surface prose; got \(coProse)")
    }

    /// Hard safety: no blocklisted token may ever be suggested, across every
    /// two-letter prefix under both a CLI and a prose context.
    func testNoProfanityEverSuggested() throws {
        let engine = try makeEngine()
        let blocked = blocklist()
        XCTAssertFalse(blocked.isEmpty)
        let letters = "abcdefghijklmnopqrstuvwxyz"
        var leaked: Set<String> = []
        for a in letters { for b in letters {
            let prefix = "\(a)\(b)"
            for proc in ["zsh", "claude"] {
                let s = engine.suggestions(forPrefix: prefix, after: nil,
                                           context: PredictionContext(foregroundProcess: proc))
                for tok in s where blocked.contains(tok.lowercased()) { leaked.insert(tok) }
            }
        }}
        XCTAssertTrue(leaked.isEmpty, "profanity leaked into suggestions: \(leaked.sorted())")
    }
}
