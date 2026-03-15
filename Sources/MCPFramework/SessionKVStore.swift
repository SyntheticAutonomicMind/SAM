// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

/// SessionKVStore.swift - Persistent key-value store for session memory
/// Ported from CLIO's session memory (.clio/memory/ files).
///
/// Stores key-value pairs per scope (conversation or shared topic).
/// JSON-backed with atomic writes. Survives app restarts.

import Foundation
import Logging

private let kvLogger = Logger(label: "com.sam.kv_store")

// MARK: - KV Entry

/// A stored key-value entry with timestamp.
struct KVEntry: Codable {
    var content: String
    var timestamp: TimeInterval

    init(content: String) {
        self.content = content
        self.timestamp = Date().timeIntervalSince1970
    }
}

/// Document format for the JSON file.
struct KVDocument: Codable {
    var entries: [String: KVEntry]
    var metadata: KVMetadata

    init() {
        entries = [:]
        metadata = KVMetadata()
    }
}

struct KVMetadata: Codable {
    var lastUpdated: TimeInterval

    init() {
        lastUpdated = Date().timeIntervalSince1970
    }

    enum CodingKeys: String, CodingKey {
        case lastUpdated = "last_updated"
    }
}

// MARK: - SessionKVStore

/// Persistent session key-value store.
/// Thread-safe via @MainActor isolation (consistent with SAM's actor model).
@MainActor
public class SessionKVStore {
    private var document: KVDocument
    private let filePath: String
    private var isDirty: Bool = false

    // MARK: - Lifecycle

    public init(filePath: String) {
        self.filePath = filePath
        self.document = KVDocument()
        load()
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: filePath) else {
            kvLogger.debug("No KV file at \(filePath), starting fresh")
            return
        }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: filePath))
            let decoder = JSONDecoder()
            document = try decoder.decode(KVDocument.self, from: data)
            kvLogger.debug("Loaded KV store from \(filePath) (\(document.entries.count) entries)")
        } catch {
            kvLogger.warning("Failed to parse KV file at \(filePath): \(error), starting fresh")
            document = KVDocument()
        }
    }

    // MARK: - Store / Retrieve

    public func store(key: String, content: String) {
        document.entries[key] = KVEntry(content: content)
        document.metadata.lastUpdated = Date().timeIntervalSince1970
        isDirty = true
        save()
    }

    public func retrieve(key: String) -> (content: String, timestamp: Date)? {
        guard let entry = document.entries[key] else { return nil }
        return (content: entry.content, timestamp: Date(timeIntervalSince1970: entry.timestamp))
    }

    public func search(query: String) -> [(key: String, content: String)] {
        let lowered = query.lowercased()
        return document.entries.compactMap { key, entry in
            if key.lowercased().contains(lowered) || entry.content.lowercased().contains(lowered) {
                return (key: key, content: entry.content)
            }
            return nil
        }
    }

    public func listKeys() -> [(key: String, preview: String)] {
        return document.entries.sorted(by: { $0.key < $1.key }).map { key, entry in
            let preview = entry.content.count > 60 ? String(entry.content.prefix(57)) + "..." : entry.content
            return (key: key, preview: preview)
        }
    }

    public func delete(key: String) -> Bool {
        guard document.entries.removeValue(forKey: key) != nil else { return false }
        document.metadata.lastUpdated = Date().timeIntervalSince1970
        isDirty = true
        save()
        return true
    }

    public var count: Int { document.entries.count }

    public var isEmpty: Bool { document.entries.isEmpty }

    // MARK: - Persistence

    private func save() {
        guard isDirty else { return }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            let data = try encoder.encode(document)

            // Ensure directory exists
            let directory = (filePath as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)

            // Atomic write
            let tempPath = filePath + ".tmp"
            try data.write(to: URL(fileURLWithPath: tempPath), options: .atomic)
            try FileManager.default.moveItem(atPath: tempPath, toPath: filePath)

            isDirty = false
            kvLogger.debug("Saved KV store to \(filePath) (\(document.entries.count) entries)")
        } catch {
            // Fallback: try direct write
            do {
                let data = try JSONEncoder().encode(document)
                try data.write(to: URL(fileURLWithPath: filePath), options: .atomic)
                isDirty = false
            } catch {
                kvLogger.error("Failed to save KV store to \(filePath): \(error)")
            }
        }
    }

    // MARK: - Path Resolution

    /// Resolve file path for a conversation's KV store.
    /// Uses shared topic directory when available, conversation-specific otherwise.
    public static func resolveFilePath(
        conversationId: UUID,
        sharedTopicId: UUID?,
        sharedTopicName: String?,
        useSharedData: Bool
    ) -> String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let samDir = appSupport.appendingPathComponent("SAM")

        if useSharedData, let topicId = sharedTopicId {
            let safeName = (sharedTopicName ?? "unnamed")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: " ", with: "_")
            let topicDir = samDir.appendingPathComponent("topics/\(safeName)_\(topicId.uuidString.prefix(8))")
            return topicDir.appendingPathComponent("kv_store.json").path
        } else {
            let convDir = samDir.appendingPathComponent("conversations/\(conversationId.uuidString)")
            return convDir.appendingPathComponent("kv_store.json").path
        }
    }
}
