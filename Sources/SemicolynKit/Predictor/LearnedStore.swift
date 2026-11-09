// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// The user's learned vocabulary: the unigram and next-token bigram stores. A value type the app records into, flushes via ``LearnedStore``,
/// and restores at launch.
public struct LearnedState: Equatable, Sendable {
    /// Learned words between fade steps.
    public static let fadeStepWords = 1000
    /// Per-step multiplier on every sketch cell: a 25-step (25,000 word) half-life.
    public static let fadeFactor: Float = pow(2, -1.0 / 25)
    /// Literals whose estimate falls below this after a fade step are dropped.
    public static let pruneThreshold: Float = 0.1
    /// Maximum literals per store (unigram and bigram separately).
    public static let literalCap = 20_000
    /// Literal count a store is pruned down to when it exceeds ``literalCap``.
    public static let literalCapTarget = 18_000

    public var unigram: LearnedVocabulary
    public var bigram: LearnedBigramVocabulary
    /// Learned words since the last fade step (always below ``fadeStepWords``).
    public var wordsSinceFade: Int

    public init(unigram: LearnedVocabulary, bigram: LearnedBigramVocabulary, wordsSinceFade: Int = 0) {
        self.unigram = unigram
        self.bigram = bigram
        self.wordsSinceFade = wordsSinceFade
    }

    /// A fresh, empty state at the spec's default dimensions, the first-launch
    /// (and fail-soft) value.
    public static var empty: LearnedState {
        LearnedState(unigram: LearnedVocabulary(), bigram: LearnedBigramVocabulary())
    }

    /// Advance the fade clock by `words` learned words. Each whole
    /// ``fadeStepWords`` applies one fade step: both stores are scaled by
    /// ``fadeFactor`` and literals below ``pruneThreshold`` are dropped. The
    /// remainder carries over. Non-positive `words` is a no-op.
    public mutating func noteLearned(words: Int) {
        guard words > 0 else { return }
        wordsSinceFade += words
        let steps = wordsSinceFade / Self.fadeStepWords
        wordsSinceFade %= Self.fadeStepWords
        for _ in 0..<steps {
            unigram.scale(by: Self.fadeFactor)
            bigram.scale(by: Self.fadeFactor)
            unigram.pruneLiterals(below: Self.pruneThreshold)
            bigram.pruneLiterals(below: Self.pruneThreshold)
        }
    }

    /// Prune each store that exceeds ``literalCap`` literals down to
    /// ``literalCapTarget``, dropping the lowest estimates first.
    public mutating func enforceCap() {
        unigram.capLiterals(max: Self.literalCap, target: Self.literalCapTarget)
        bigram.capLiterals(max: Self.literalCap, target: Self.literalCapTarget)
    }

    /// True when either store holds more than ``literalCap`` literals (O(1)).
    var exceedsCap: Bool {
        unigram.literalCount > Self.literalCap || bigram.literalCount > Self.literalCap
    }
}

/// Persists the learned state to disk under a caller-provided `directory` (the app
/// passes the predictor dir; tests pass a temp dir). `save` overwrites atomically,
/// `load` is fail-soft to an empty state. Both stores live in one
/// atomically-written `learned.sketch`, so a thrown/interrupted save never pairs a
/// fresh unigram state with a stale bigram one. See `2026-06-21-predictor-learned-store-design`.
public struct LearnedStore {
    private let directory: URL

    private var fileURL: URL { directory.appendingPathComponent("learned.sketch") }

    private static let magic: [UInt8] = [0x47, 0x4c, 0x52, 0x4e]  // "GLRN"
    private static let formatVersion: UInt8 = 1
    private static let headerSize = 5  // magic(4) + version(1)

    public init(directory: URL) {
        self.directory = directory
    }

    /// Persist `state` atomically, overwriting any prior save and creating
    /// `directory` if absent.
    public func save(_ state: LearnedState) throws {
        var out: [UInt8] = []
        out.append(contentsOf: Self.magic)
        out.append(Self.formatVersion)
        appendSubBlob(&out, state.unigram.serialize())
        appendSubBlob(&out, state.bigram.serialize())

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(iOS)
        try Data(out).write(to: fileURL, options: [.atomic, .completeFileProtection])
        #else
        try Data(out).write(to: fileURL, options: [.atomic])
        #endif
    }

    /// The persisted learned state, or a fresh-empty one when no file exists (first
    /// launch) or the file is corrupt. Never throws and never returns nil: a
    /// missing or damaged store restarts learning rather than breaking input.
    ///
    /// Caller caution: an empty result does **not** prove the user has no history,
    /// a *transient* read failure also yields empty (notably an iOS
    /// `NSFileProtectionComplete` file is unreadable while the device is locked).
    /// Callers must not treat an empty load as authoritative and unconditionally
    /// overwrite it, or recoverable data is lost. Higher-fidelity recovery (the
    /// append-only event log) is a later slice; empty is the safe v1 floor.
    public func load() -> LearnedState {
        guard let data = try? Data(contentsOf: fileURL) else { return .empty }
        let bytes = [UInt8](data)
        guard bytes.count >= Self.headerSize,
              Array(bytes[0..<4]) == Self.magic,
              bytes[4] == Self.formatVersion else { return .empty }
        var p = Self.headerSize
        guard let unigramBlob = readLengthPrefixed(bytes, &p),
              let bigramBlob = readLengthPrefixed(bytes, &p),
              p == bytes.count,                                   // no trailing slack
              let unigram = LearnedVocabulary(deserializing: unigramBlob),
              let bigram = LearnedBigramVocabulary(deserializing: bigramBlob) else { return .empty }
        return LearnedState(unigram: unigram, bigram: bigram)
    }

    /// Delete the persisted learned store. Idempotent: a missing file is not an error
    /// (panic-purge on a never-saved store must not throw). Other I/O errors propagate.
    public func delete() throws {
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        }
    }
}
