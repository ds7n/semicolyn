// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Incremental newline splitter: feed byte chunks of any size and receive each complete line
/// (without `\n` or a trailing `\r`; empty lines are skipped). A line may straddle chunks; call
/// ``finish(_:)`` at end of input to flush an unterminated last line.
public struct LineSplitter: Sendable {
    private var carry: [UInt8] = []

    public init() {}

    /// Delivers every line completed by `chunk`.
    public mutating func feed(_ chunk: [UInt8], _ body: (Substring) -> Void) {
        var start = 0
        for (i, byte) in chunk.enumerated() where byte == 0x0A {
            emit(chunk[start..<i], body)
            start = i + 1
        }
        if start < chunk.count { carry.append(contentsOf: chunk[start...]) }
    }

    /// Delivers the unterminated last line, if any.
    public mutating func finish(_ body: (Substring) -> Void) {
        guard !carry.isEmpty else { return }
        emit([], body)
    }

    private mutating func emit(_ tail: ArraySlice<UInt8>, _ body: (Substring) -> Void) {
        var line = carry
        line.append(contentsOf: tail)
        carry.removeAll(keepingCapacity: true)
        while line.last == 0x0D { line.removeLast() }
        guard !line.isEmpty else { return }
        body(Substring(String(decoding: line, as: UTF8.self)))
    }
}

/// Streams a file line by line in `chunkSize` reads, never holding more than one chunk
/// plus one partial line. Throws if the file cannot be opened or read.
public func forEachLine(inFile path: String, chunkSize: Int = 1 << 20, _ body: (Substring) -> Void) throws {
    guard let handle = FileHandle(forReadingAtPath: path) else {
        throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: path])
    }
    defer { try? handle.close() }
    var splitter = LineSplitter()
    while let data = try handle.read(upToCount: chunkSize), !data.isEmpty {
        splitter.feed([UInt8](data), body)
    }
    splitter.finish(body)
}
