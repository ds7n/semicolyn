// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import SemicolynKit

/// Assemble the two serialized blobs into the single seed_pinned-format blob the app
/// installs. Thin wrapper over `BundledSeed.combinedBlob()` so `main.swift` stays glue.
public func combinedSeedBlob(version: Int, unigram: [UInt8], bigram: [UInt8]) -> [UInt8] {
    BundledSeed(version: version, unigramBlob: unigram, bigramBlob: bigram).combinedBlob()
}
