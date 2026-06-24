// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// The swappable backend for CloudKit-bound records: opaque `Data` blobs keyed
/// by `(type, id)`. The CloudKit Private DB implements this on Apple (Phase 2b);
/// `InMemoryBlobStore`/`FileBlobStore` back tests and local persistence.
///
/// Blobs are opaque to the store — `EncryptedRecordStore` seals/opens them, so a
/// backend (and CloudKit) only ever sees AES-GCM ciphertext.
public protocol BlobStore {
    /// Store `data` under `(type, id)`, overwriting any existing blob.
    func putBlob(_ data: Data, type: String, id: UUID) throws
    /// The blob at `(type, id)`, or `nil` if none exists.
    func getBlob(type: String, id: UUID) throws -> Data?
    /// Remove the blob at `(type, id)`. Idempotent — removing a missing blob is a no-op.
    func deleteBlob(type: String, id: UUID) throws
    /// Every `(id, data)` pair stored under `type`, in unspecified order.
    func listBlobs(type: String) throws -> [(id: UUID, data: Data)]
}

/// In-memory `BlobStore` for tests and previews. Not thread-safe; intended for
/// single-actor use.
public final class InMemoryBlobStore: BlobStore {
    private var store: [String: [UUID: Data]] = [:]

    public init() {}

    public func putBlob(_ data: Data, type: String, id: UUID) throws {
        store[type, default: [:]][id] = data
    }

    public func getBlob(type: String, id: UUID) throws -> Data? {
        store[type]?[id]
    }

    public func deleteBlob(type: String, id: UUID) throws {
        store[type]?[id] = nil
    }

    public func listBlobs(type: String) throws -> [(id: UUID, data: Data)] {
        (store[type] ?? [:]).map { (id: $0.key, data: $0.value) }
    }
}

/// File-backed `BlobStore` for local persistence and Linux integration tests.
/// Layout: one file per record at `<directory>/<type>/<uuid>.rec`. Writes are
/// atomic (mirrors `LearnedStore`); on iOS the file gets complete data protection.
public struct FileBlobStore: BlobStore {
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    private func typeDir(_ type: String) -> URL {
        directory.appendingPathComponent(type, isDirectory: true)
    }

    private func fileURL(type: String, id: UUID) -> URL {
        typeDir(type).appendingPathComponent("\(id.uuidString).rec")
    }

    public func putBlob(_ data: Data, type: String, id: UUID) throws {
        try FileManager.default.createDirectory(at: typeDir(type), withIntermediateDirectories: true)
        #if os(iOS)
        try data.write(to: fileURL(type: type, id: id), options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: fileURL(type: type, id: id), options: [.atomic])
        #endif
    }

    public func getBlob(type: String, id: UUID) throws -> Data? {
        try? Data(contentsOf: fileURL(type: type, id: id))
    }

    public func deleteBlob(type: String, id: UUID) throws {
        let url = fileURL(type: type, id: id)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    public func listBlobs(type: String) throws -> [(id: UUID, data: Data)] {
        let dir = typeDir(type)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        var out: [(id: UUID, data: Data)] = []
        for name in names {
            guard name.hasSuffix(".rec"),
                  let id = UUID(uuidString: String(name.dropLast(4))),  // strip ".rec"; skip unparseable
                  let data = try? Data(contentsOf: dir.appendingPathComponent(name)) else { continue }
            out.append((id: id, data: data))
        }
        return out
    }
}
