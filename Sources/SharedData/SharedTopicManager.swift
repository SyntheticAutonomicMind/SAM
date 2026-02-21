// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging
import ConfigurationSystem

private let topicLogger = Logger(label: "com.sam.shared.TopicManager")

public struct SharedTopic {
    public let id: String
    public let name: String
    public let description: String?
}

public final class SharedTopicManager {
    private let storage: SharedStorage

    /// Primary initializer with explicit storage
    public init(storage: SharedStorage) {
        self.storage = storage
    }
    
    /// Convenience initializer using shared storage
    /// Falls back to creating new storage if shared instance is nil
    public convenience init() {
        if let sharedStorage = SharedStorage.shared {
            self.init(storage: sharedStorage)
        } else {
            topicLogger.error("SharedStorage.shared is nil, attempting to create new instance")
            do {
                let newStorage = try SharedStorage()
                self.init(storage: newStorage)
            } catch {
                topicLogger.error("Failed to create SharedStorage: \(error.localizedDescription)")
                fatalError("Cannot initialize SharedTopicManager without valid SharedStorage")
            }
        }
    }

    /// Get the files directory path for a shared topic
    /// Format: {basePath}/{topicName}/ (user-friendly, matches conversation pattern)
    public static func getTopicFilesDirectory(topicId: String, topicName: String) -> URL {
        let safeName = topicName.replacingOccurrences(of: "/", with: "-")
        let topicDirPath = WorkingDirectoryConfiguration.shared.buildPath(subdirectory: safeName)
        return URL(fileURLWithPath: topicDirPath, isDirectory: true)
    }

    /// Create the files directory for a topic
    private func createTopicFilesDirectory(topicId: String, topicName: String) throws {
        let filesDir = SharedTopicManager.getTopicFilesDirectory(topicId: topicId, topicName: topicName)
        let fm = FileManager.default
        if !fm.fileExists(atPath: filesDir.path) {
            try fm.createDirectory(at: filesDir, withIntermediateDirectories: true)
            topicLogger.debug("Created topic files directory: \(filesDir.path)")
        }
    }

    public func createTopic(id: String = UUID().uuidString, name: String, description: String? = nil, ownerUserId: String? = nil, acl: String? = nil) throws -> SharedTopic {
        /// Check for existing topic with the same name to prevent duplicates
        let existing = try storage.queryRows("SELECT id, name, description FROM topics WHERE name = ?", params: [name])
        if let existingTopic = existing.first, let existingId = existingTopic["id"], let existingName = existingTopic["name"] {
            topicLogger.debug("Topic with name '\(name)' already exists (id: \(existingId)), returning existing topic")
            return SharedTopic(id: existingId, name: existingName, description: existingTopic["description"])
        }

        let sql = "INSERT INTO topics (id, name, ownerUserId, description, acl) VALUES (?, ?, ?, ?, ?)"
        try storage.runStatement(sql, params: [id, name, ownerUserId ?? "", description ?? "", acl ?? ""])

        // Create the files directory for this topic
        try createTopicFilesDirectory(topicId: id, topicName: name)

        topicLogger.debug("Created topic \(id) name=\(name)")
        return SharedTopic(id: id, name: name, description: description)
    }

    public func listTopics() throws -> [SharedTopic] {
        let rows = try storage.queryRows("SELECT id, name, description FROM topics ORDER BY createdAt DESC")
        return rows.compactMap { r in
            guard let id = r["id"], let name = r["name"] else { return nil }
            return SharedTopic(id: id, name: name, description: r["description"])
        }
    }

    /// Update topic name and/or description
    public func updateTopic(id: UUID, name: String, description: String? = nil) throws {
        // Get the old topic to check if name changed
        let rows = try storage.queryRows("SELECT name FROM topics WHERE id = ?", params: [id.uuidString])
        guard let oldRow = rows.first, let oldName = oldRow["name"] else {
            throw NSError(domain: "SharedTopicManager", code: 404, userInfo: [NSLocalizedDescriptionKey: "Topic not found"])
        }

        // Update topic in database
        let sql = "UPDATE topics SET name = ?, description = ?, updatedAt = CURRENT_TIMESTAMP WHERE id = ?"
        try storage.runStatement(sql, params: [name, description ?? "", id.uuidString])

        // If name changed, rename the directory
        if oldName != name {
            let oldDir = SharedTopicManager.getTopicFilesDirectory(topicId: id.uuidString, topicName: oldName)
            let newDir = SharedTopicManager.getTopicFilesDirectory(topicId: id.uuidString, topicName: name)

            let fm = FileManager.default
            if fm.fileExists(atPath: oldDir.path) {
                try fm.moveItem(at: oldDir, to: newDir)
                topicLogger.debug("Renamed topic directory: \(oldDir.path) -> \(newDir.path)")
            }
        }

        try logAudit(topicId: id.uuidString, action: "update_topic", performedBy: "system", details: "name=\(name)")
        topicLogger.debug("Updated topic \(id.uuidString) name=\(name)")
    }

    /// Delete topic and all associated data
    public func deleteTopic(id: UUID) throws {
        // Get topic name for directory deletion
        let rows = try storage.queryRows("SELECT name FROM topics WHERE id = ?", params: [id.uuidString])
        guard let row = rows.first, let name = row["name"] else {
            throw NSError(domain: "SharedTopicManager", code: 404, userInfo: [NSLocalizedDescriptionKey: "Topic not found"])
        }

        // Delete from database (cascade will handle entries, locks, audit)
        let sql = "DELETE FROM topics WHERE id = ?"
        try storage.runStatement(sql, params: [id.uuidString])

        // Delete the files directory
        let topicDir = SharedTopicManager.getTopicFilesDirectory(topicId: id.uuidString, topicName: name)
        let fm = FileManager.default
        if fm.fileExists(atPath: topicDir.path) {
            try fm.removeItem(at: topicDir)
            topicLogger.debug("Deleted topic directory: \(topicDir.path)")
        }

        topicLogger.debug("Deleted topic \(id.uuidString) name=\(name)")
    }

    public func createEntry(topicId: String, entryId: String = UUID().uuidString, key: String? = nil, content: String, contentType: String? = nil, createdBy: String? = nil) throws {
        let sql = "INSERT INTO entries (id, topicId, key, content, contentType, createdBy) VALUES (?, ?, ?, ?, ?, ?)"
        try storage.runStatement(sql, params: [entryId, topicId, key ?? "", content, contentType ?? "", createdBy ?? ""])
        try logAudit(topicId: topicId, action: "create_entry", performedBy: createdBy ?? "system", details: "entryId=\(entryId)")
    }

    public func listEntries(topicId: String) throws -> [[String: String]] {
        return try storage.queryRows("SELECT id, key, content, contentType, createdBy, createdAt FROM entries WHERE topicId = ? ORDER BY createdAt DESC", params: [topicId])
    }

    /// Get single entry by ID
    public func getEntry(topicId: String, entryId: String) throws -> [String: String]? {
        let rows = try storage.queryRows("SELECT id, key, content, contentType, createdBy, createdAt FROM entries WHERE topicId = ? AND id = ?", params: [topicId, entryId])
        return rows.first
    }

    /// Update entry content and/or key
    public func updateEntry(topicId: String, entryId: String, key: String? = nil, content: String, contentType: String? = nil, updatedBy: String? = nil) throws {
        let sql = "UPDATE entries SET key = ?, content = ?, contentType = ?, updatedAt = CURRENT_TIMESTAMP WHERE topicId = ? AND id = ?"
        try storage.runStatement(sql, params: [key ?? "", content, contentType ?? "", topicId, entryId])
        try logAudit(topicId: topicId, action: "update_entry", performedBy: updatedBy ?? "system", details: "entryId=\(entryId)")
    }

    /// Delete entry
    public func deleteEntry(topicId: String, entryId: String, deletedBy: String? = nil) throws {
        let sql = "DELETE FROM entries WHERE topicId = ? AND id = ?"
        try storage.runStatement(sql, params: [topicId, entryId])
        try logAudit(topicId: topicId, action: "delete_entry", performedBy: deletedBy ?? "system", details: "entryId=\(entryId)")
    }

    /// Search entries by query string (searches in key and content)
    public func searchEntries(topicId: String, query: String) throws -> [[String: String]] {
        let sql = "SELECT id, key, content, contentType, createdBy, createdAt FROM entries WHERE topicId = ? AND (key LIKE ? OR content LIKE ?) ORDER BY createdAt DESC"
        let pattern = "%\(query)%"
        return try storage.queryRows(sql, params: [topicId, pattern, pattern])
    }

    // MARK: - Lock Management

    /// Acquire lock on topic
    public func acquireLock(topicId: String, lockedBy: String, ttlSeconds: Int? = nil) throws {
        // Check if already locked
        let existing = try storage.queryRows("SELECT lockedBy, acquiredAt, ttlSeconds FROM locks WHERE topicId = ?", params: [topicId])
        if let lock = existing.first {
            let acquiredAtStr = lock["acquiredAt"] ?? ""
            if let ttl = lock["ttlSeconds"], let ttlInt = Int(ttl), !acquiredAtStr.isEmpty {
                // Check if lock is expired
                let formatter = ISO8601DateFormatter()
                if let acquiredDate = formatter.date(from: acquiredAtStr) {
                    let expiresDate = acquiredDate.addingTimeInterval(TimeInterval(ttlInt))
                    if expiresDate > Date() {
                        throw NSError(domain: "SharedTopicManager", code: 409, userInfo: [
                            NSLocalizedDescriptionKey: "Topic is locked by \(lock["lockedBy"] ?? "unknown")"
                        ])
                    }
                }
            } else {
                throw NSError(domain: "SharedTopicManager", code: 409, userInfo: [
                    NSLocalizedDescriptionKey: "Topic is locked by \(lock["lockedBy"] ?? "unknown")"
                ])
            }
        }

        // Acquire lock
        let acquiredAt = ISO8601DateFormatter().string(from: Date())
        let ttlStr = ttlSeconds.map { String($0) } ?? ""
        let sql = "INSERT OR REPLACE INTO locks (topicId, lockedBy, acquiredAt, ttlSeconds) VALUES (?, ?, ?, ?)"
        try storage.runStatement(sql, params: [topicId, lockedBy, acquiredAt, ttlStr])
        try logAudit(topicId: topicId, action: "acquire_lock", performedBy: lockedBy, details: "ttl=\(ttlStr)")
    }

    /// Release lock on topic
    public func releaseLock(topicId: String, releasedBy: String) throws {
        let sql = "DELETE FROM locks WHERE topicId = ?"
        try storage.runStatement(sql, params: [topicId])
        try logAudit(topicId: topicId, action: "release_lock", performedBy: releasedBy, details: "")
    }

    /// Get lock status
    public func getLockStatus(topicId: String) throws -> [String: String]? {
        let rows = try storage.queryRows("SELECT lockedBy, acquiredAt, ttlSeconds FROM locks WHERE topicId = ?", params: [topicId])
        return rows.first
    }

    private func logAudit(topicId: String, action: String, performedBy: String, details: String) throws {
        let id = UUID().uuidString
        let sql = "INSERT INTO audit (id, topicId, action, performedBy, details) VALUES (?, ?, ?, ?, ?)"
        try storage.runStatement(sql, params: [id, topicId, action, performedBy, details])
    }
}
