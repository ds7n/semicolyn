// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

// Read-only parser for the pre-fade plaintext `learned.sketch` (GLRN v1), kept only
// so ``LearnedStore`` can migrate it once into the sealed file. Layout:
//
//   GLRN | 1 | unigram sub-blob | bigram sub-blob          (each LE32 length-prefixed)
//   unigram: GRLV | 1 | index | today | rolling7 | rolling30 | rolling90 | dailyCount LE32 | dailies...
//   bigram:  GRBG | 1 | GRLV blob (rest of bytes, no length prefix)
//
// Sketches are CountMinSketch format v1 (UInt32 cells). See
// `2026-11-08-predictor-learned-fade-design` ("Migration").

private let legacyFileMagic: [UInt8] = [0x47, 0x4c, 0x52, 0x4e]     // "GLRN"
private let legacyRollingMagic: [UInt8] = [0x47, 0x52, 0x4c, 0x56]  // "GRLV"
private let legacyBigramMagic: [UInt8] = [0x47, 0x52, 0x42, 0x47]   // "GRBG"
private let legacyFormatVersion: UInt8 = 1
private let legacyHeaderSize = 5  // magic(4) + version(1)
/// The old retention horizon: a real file never held more dailies than this.
private let legacyRetentionDays = 90

/// The learned state recovered from an old GLRN v1 `learned.sketch`, or `nil` when
/// the bytes are not exactly that layout (fail closed). Each store collapses to
/// `today` merged with `rolling90` (rolling7/30 are subsets of rolling90 and the
/// dailies are its components, so they are framed but not added). Literals are
/// kept, `wordsSinceFade` starts at 0, then the literal cap is applied.
func legacyLearnedState(_ bytes: [UInt8]) -> LearnedState? {
    guard hasLegacyHeader(bytes, legacyFileMagic) else { return nil }
    var p = legacyHeaderSize
    guard let unigramBlob = readLengthPrefixed(bytes, &p),
          let bigramBlob = readLengthPrefixed(bytes, &p),
          p == bytes.count,                                         // no trailing slack
          hasLegacyHeader(bigramBlob, legacyBigramMagic),
          let unigram = legacyVocabulary(unigramBlob, depth: 4, width: 1 << 14),
          let bigram = legacyVocabulary(Array(bigramBlob[legacyHeaderSize...]),
                                        depth: 4, width: 1 << 16) else { return nil }
    var state = LearnedState(unigram: unigram, bigram: LearnedBigramVocabulary(vocabulary: bigram))
    state.enforceCap()
    return state
}

/// True when `bytes` starts with `magic` and the legacy format version.
private func hasLegacyHeader(_ bytes: [UInt8], _ magic: [UInt8]) -> Bool {
    bytes.count >= legacyHeaderSize && Array(bytes[0..<4]) == magic && bytes[4] == legacyFormatVersion
}

/// One old GRLV state as a ``LearnedVocabulary`` (`today` merged with `rolling90`),
/// or `nil` on a framing error, trailing slack, too many dailies, or a `today` /
/// `rolling90` sketch that is not `depth` x `width`.
private func legacyVocabulary(_ bytes: [UInt8], depth: Int, width: Int) -> LearnedVocabulary? {
    guard hasLegacyHeader(bytes, legacyRollingMagic) else { return nil }
    var p = legacyHeaderSize
    guard let indexBlob = readLengthPrefixed(bytes, &p),
          let index = PrefixIndex(deserializing: indexBlob),
          var sketch = readSketch(bytes, &p),
          readLengthPrefixed(bytes, &p) != nil,                    // rolling7 (subset of rolling90)
          readLengthPrefixed(bytes, &p) != nil,                    // rolling30 (subset of rolling90)
          let rolling90 = readSketch(bytes, &p),
          let dailyCount = readLE32(bytes, p),
          dailyCount <= legacyRetentionDays else { return nil }
    p += 4
    for _ in 0..<Int(dailyCount) {                                  // components of rolling90
        guard readLengthPrefixed(bytes, &p) != nil else { return nil }
    }
    guard p == bytes.count,
          sketch.depth == depth, sketch.width == width,
          sketch.merge(rolling90) else { return nil }               // false on mismatched dimensions
    return LearnedVocabulary(index: index, sketch: sketch)
}
