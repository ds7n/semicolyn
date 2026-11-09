// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto   // Apple's swift-crypto, API-compatible on Linux
#endif

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

/// The outcome of ``LearnedStore/load()``, tri-state like the sealed settings.
public enum LearnedLoad: Equatable, Sendable {
    /// The stored (or just-migrated) state.
    case found(LearnedState)
    /// Nothing usable stored: no file, or one that won't decrypt or parse (another
    /// record key, tampering, corruption). Start empty; saving over it is fine.
    case absent
    /// A file exists but can't be read (on iOS: a complete-protection file while the
    /// device is locked). Don't learn or save this session, so it isn't overwritten.
    case unreadable
}

/// Persists the learned state under a caller-provided `directory` (the app passes
/// the predictor dir; tests pass a temp dir) as `learned.sealed`: AES-GCM with the
/// record key over `"GLFD" | version 1 | wordsSinceFade LE32 | unigram sub-blob |
/// bigram sub-blob` (sub-blobs LE32 length-prefixed). One atomically-written file,
/// so a thrown or interrupted save never pairs a fresh unigram store with a stale
/// bigram one. An old plaintext `learned.sketch` (GLRN v1) migrates once on load.
/// See `2026-11-08-predictor-learned-fade-design`.
public struct LearnedStore {
    private let directory: URL
    private let key: SymmetricKey
    /// Atomic file write, injectable so tests can fail the sealed write while the
    /// directory stays writable.
    private let write: (Data, URL) throws -> Void

    private var sealedURL: URL { directory.appendingPathComponent("learned.sealed") }
    private var legacyURL: URL { directory.appendingPathComponent("learned.sketch") }

    private static let magic: [UInt8] = [0x47, 0x4c, 0x46, 0x44]  // "GLFD"
    private static let formatVersion: UInt8 = 1
    private static let headerSize = 9  // magic(4) + version(1) + wordsSinceFade(4)

    /// A store under `directory`, sealed with `key` (the record key).
    public init(directory: URL, key: SymmetricKey) {
        self.init(directory: directory, key: key, write: Self.atomicWrite)
    }

    /// As ``init(directory:key:)`` with the atomic-write step replaced (test seam).
    init(directory: URL, key: SymmetricKey, write: @escaping (Data, URL) throws -> Void) {
        self.directory = directory
        self.key = key
        self.write = write
    }

    private static func atomicWrite(_ data: Data, to url: URL) throws {
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: url, options: [.atomic])
        #endif
    }

    /// Seal and persist `state` atomically, overwriting any prior save and creating
    /// `directory` if absent. Throws on a sealing or I/O failure.
    public func save(_ state: LearnedState) throws {
        let box = try AES.GCM.seal(Data(Self.serialize(state)), using: key)
        // `combined` is nil only for a non-default nonce size; `seal(_:using:)`
        // always uses the default 12-byte nonce, so this cannot fail.
        let sealed = box.combined!
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try write(sealed, sealedURL)
        // The sealed copy is durable: no plaintext may outlive it (a failed earlier
        // removal, or a malformed legacy file that never migrated).
        try? FileManager.default.removeItem(at: legacyURL)
    }

    /// The persisted learned state. Never throws:
    /// - `learned.sealed` present: a read error is ``LearnedLoad/unreadable``; a file
    ///   that won't open or parse is ``LearnedLoad/absent``. Any leftover
    ///   `learned.sketch` is removed (best effort).
    /// - Otherwise an old `learned.sketch`: a read error is `.unreadable`, a parse
    ///   failure `.absent`; a parsed one is sealed and the old file deleted only if
    ///   that save succeeded (a failed save retries next session). `.found` either way.
    /// - Neither: `.absent`.
    public func load() -> LearnedLoad {
        let files = FileManager.default
        if files.fileExists(atPath: sealedURL.path) {
            guard let data = try? Data(contentsOf: sealedURL) else { return .unreadable }
            guard let box = try? AES.GCM.SealedBox(combined: data),
                  let plain = try? AES.GCM.open(box, using: key),
                  let state = Self.deserialize([UInt8](plain)) else { return .absent }
            try? files.removeItem(at: legacyURL)   // leftover plaintext from a failed removal
            return .found(state)
        }
        guard files.fileExists(atPath: legacyURL.path) else { return .absent }
        guard let data = try? Data(contentsOf: legacyURL) else { return .unreadable }
        guard let migrated = legacyLearnedState([UInt8](data)) else { return .absent }
        // `save` removes the legacy file only after the sealed write succeeds.
        try? save(migrated)
        return .found(migrated)
    }

    /// Delete `learned.sealed` and any old `learned.sketch`. Idempotent: a missing
    /// file is not an error (panic-purge on a never-saved store must not throw).
    /// Other I/O errors propagate.
    public func delete() throws {
        try Self.removeIfPresent(sealedURL)
        try Self.removeIfPresent(legacyURL)
    }

    private static func removeIfPresent(_ url: URL) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        }
    }

    /// The sealed plaintext: `magic | version | wordsSinceFade | unigram | bigram`.
    /// The fade clock is normalized below ``LearnedState/fadeStepWords`` so a valid
    /// state never writes a value ``deserialize(_:)`` rejects.
    private static func serialize(_ state: LearnedState) -> [UInt8] {
        var out: [UInt8] = []
        out.append(contentsOf: magic)
        out.append(formatVersion)
        appendLE32(&out, UInt32(clamping: state.wordsSinceFade % LearnedState.fadeStepWords))
        appendSubBlob(&out, state.unigram.serialize())
        appendSubBlob(&out, state.bigram.serialize())
        return out
    }

    /// Parse the sealed plaintext. Fails closed (`nil`) on wrong magic/version, a
    /// fade clock at or past ``LearnedState/fadeStepWords``, a rejected or
    /// wrong-dimension sub-blob, or trailing slack.
    private static func deserialize(_ bytes: [UInt8]) -> LearnedState? {
        guard bytes.count >= headerSize,
              Array(bytes[0..<4]) == magic,
              bytes[4] == formatVersion,
              let rawWords = readLE32(bytes, 5),
              rawWords < LearnedState.fadeStepWords else { return nil }
        var p = headerSize
        guard let unigramBlob = readLengthPrefixed(bytes, &p),
              let bigramBlob = readLengthPrefixed(bytes, &p),
              p == bytes.count,                                   // no trailing slack
              let unigram = LearnedVocabulary(deserializing: unigramBlob),
              let bigram = LearnedBigramVocabulary(deserializing: bigramBlob) else { return nil }
        return LearnedState(unigram: unigram, bigram: bigram, wordsSinceFade: Int(rawWords))
    }
}
