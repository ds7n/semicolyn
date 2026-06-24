// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// The user's learned windowed vocabulary: the unigram and next-token bigram
/// rolling stores. A value type the app records into, flushes via ``LearnedStore``,
/// and restores at launch.
public struct LearnedState: Equatable, Sendable {
    public var unigram: RollingVocabulary
    public var bigram: RollingBigramVocabulary

    public init(unigram: RollingVocabulary, bigram: RollingBigramVocabulary) {
        self.unigram = unigram
        self.bigram = bigram
    }

    /// A fresh, empty state at the spec's default dimensions — the first-launch
    /// (and fail-soft) value.
    public static var empty: LearnedState {
        LearnedState(unigram: RollingVocabulary(), bigram: RollingBigramVocabulary())
    }
}

/// Persists the learned state to disk under a caller-provided `directory` (the app
/// passes the predictor dir; tests pass a temp dir). The read-write counterpart to
/// ``SeedStore``: `save` overwrites atomically, `load` is fail-soft to an empty
/// state. Both rolling states live in one atomically-written `learned.sketch`, so
/// a thrown/interrupted save never pairs a fresh unigram state with a stale bigram
/// one. See `2026-06-21-predictor-learned-store-design`.
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
    /// Caller caution: an empty result does **not** prove the user has no history —
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
              let unigram = RollingVocabulary(deserializing: unigramBlob),
              let bigram = RollingBigramVocabulary(deserializing: bigramBlob) else { return .empty }
        return LearnedState(unigram: unigram, bigram: bigram)
    }
}
