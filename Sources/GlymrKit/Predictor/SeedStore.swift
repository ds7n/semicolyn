// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// A seed shipped with the app: a content version plus the two serialized blobs
/// (unigram ``Vocabulary`` + next-token ``BigramVocabulary``). The app builds this
/// from its `Bundle` resources; tests build it from in-memory stores. The
/// `version` is the seed *content* release (`seed_v<N>`), distinct from the blob
/// *format* version the deserializers carry.
public struct BundledSeed: Sendable {
    public let version: Int
    public let unigramBlob: [UInt8]
    public let bigramBlob: [UInt8]

    public init(version: Int, unigramBlob: [UInt8], bigramBlob: [UInt8]) {
        self.version = version
        self.unigramBlob = unigramBlob
        self.bigramBlob = bigramBlob
    }
}

/// The loaded, queryable seed: a unigram vocabulary and a next-token bigram store,
/// both already conforming to / exposing ``CandidateSource`` for ranking.
public struct PredictorSeed: Sendable {
    public let unigram: Vocabulary
    public let bigram: BigramVocabulary
}

/// Manages the pinned seed on disk under a caller-provided `directory` (the app
/// passes the predictor dir; tests pass a temp dir). Installs the bundled seed on
/// first launch or version upgrade, and loads it back fail-soft. The first
/// filesystem-touching component in the predictor. See
/// `2026-06-21-predictor-seed-runtime-load-design`.
///
/// Both blobs and the content version live in **one** `seed_pinned.sketch` file
/// written atomically, so an install is all-or-nothing: there is no window where
/// a new unigram blob can pair with an old bigram blob.
public struct SeedStore {
    private let directory: URL

    private var pinnedURL: URL { directory.appendingPathComponent("seed_pinned.sketch") }

    private static let magic: [UInt8] = [0x47, 0x53, 0x45, 0x44]  // "GSED"
    private static let formatVersion: UInt8 = 1
    private static let headerSize = 9  // magic(4) + formatVersion(1) + contentVersion(4)

    public init(directory: URL) {
        self.directory = directory
    }

    /// Install `bundled` unless an up-to-date, *readable* seed is already present.
    /// Reinstalls when nothing is installed, when the bundle is newer, **or** when
    /// the installed file is corrupt/unreadable — so a damaged seed self-heals on
    /// the next launch instead of waiting for a version bump. Returns whether an
    /// install happened. The single atomic write means a thrown/interrupted install
    /// never leaves a half-updated or mismatched seed — the prior file (or none)
    /// survives intact.
    @discardableResult
    public func installIfNeeded(_ bundled: BundledSeed) throws -> Bool {
        if let installed = installedVersion(), bundled.version <= installed, loadSeed() != nil {
            return false
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try write(combinedBlob(bundled), to: pinnedURL)
        return true
    }

    /// The pinned seed, or `nil` if none is installed or the file is
    /// absent/corrupt/truncated. Fail-soft by contract: a missing or damaged seed
    /// degrades the predictor to learned-only — it must never throw and break
    /// input. Both sub-blobs come from the same atomically-written file, so they
    /// always belong to the same content release.
    public func loadSeed() -> PredictorSeed? {
        guard let bytes = pinnedBytes(),
              bytes.count >= Self.headerSize,
              Array(bytes[0..<4]) == Self.magic,
              bytes[4] == Self.formatVersion else { return nil }
        var p = Self.headerSize
        guard let unigramBlob = readLengthPrefixed(bytes, &p),
              let bigramBlob = readLengthPrefixed(bytes, &p),
              p == bytes.count,                                   // no trailing slack
              let unigram = Vocabulary(deserializing: unigramBlob),
              let bigram = BigramVocabulary(deserializing: bigramBlob) else { return nil }
        return PredictorSeed(unigram: unigram, bigram: bigram)
    }

    /// The installed seed content version, or `nil` if the file is absent or its
    /// header is invalid — either treated as not-installed, so a corrupt file
    /// triggers a clean re-install rather than wedging on a bad seed.
    private func installedVersion() -> Int? {
        guard let bytes = pinnedBytes(),
              bytes.count >= Self.headerSize,
              Array(bytes[0..<4]) == Self.magic,
              bytes[4] == Self.formatVersion,
              let version = readLE32(bytes, 5) else { return nil }
        return Int(version)
    }

    /// Read the whole pinned file, or `nil` if unreadable.
    private func pinnedBytes() -> [UInt8]? {
        guard let data = try? Data(contentsOf: pinnedURL) else { return nil }
        return [UInt8](data)
    }

    /// `magic | formatVersion | contentVersion | len|unigram | len|bigram`. The
    /// content version is clamped to non-negative (a seed release counter).
    private func combinedBlob(_ bundled: BundledSeed) -> [UInt8] {
        var out: [UInt8] = []
        out.append(contentsOf: Self.magic)
        out.append(Self.formatVersion)
        appendLE32(&out, UInt32(max(0, bundled.version)))
        appendLE32(&out, UInt32(bundled.unigramBlob.count))
        out.append(contentsOf: bundled.unigramBlob)
        appendLE32(&out, UInt32(bundled.bigramBlob.count))
        out.append(contentsOf: bundled.bigramBlob)
        return out
    }

    /// Atomically write `bytes` to `url`, applying complete file protection on iOS
    /// so the at-rest seed is encrypted with the rest of the predictor data.
    private func write(_ bytes: [UInt8], to url: URL) throws {
        #if os(iOS)
        try Data(bytes).write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try Data(bytes).write(to: url, options: [.atomic])
        #endif
    }
}
