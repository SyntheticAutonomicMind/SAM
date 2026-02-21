// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import SQLite3
import Logging

/// Minimal SQLite-backed storage adapter for shared topics.
/// This file provides a lightweight wrapper around SQLite using `sqlite3` C API
/// to avoid introducing new package dependencies in the initial implementation.

private let logger = Logger(label: "com.sam.shared.SharedStorage")

public enum SharedStorageError: Error {
    case initializationFailed(String)
    case queryFailed(String)
}

public final class SharedStorage {
    public nonisolated(unsafe) static let shared = try? SharedStorage()

    private let dbURL: URL
    var db: OpaquePointer?

    public init() throws {
        let fm = FileManager.default
        let appSupport = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let samDir = appSupport.appendingPathComponent("SAM", isDirectory: true)
        if !fm.fileExists(atPath: samDir.path) {
            try fm.createDirectory(at: samDir, withIntermediateDirectories: true)
        }

        self.dbURL = samDir.appendingPathComponent("shared_memory.db")

        // Open or create database
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(dbURL.path, &db, flags, nil) != SQLITE_OK {
            let err = String(cString: sqlite3_errmsg(db))
            logger.error("Failed to open sqlite: \(err)")
            throw SharedStorageError.initializationFailed(err)
        }

        try migrateIfNeeded()
        logger.debug("SharedStorage initialized at \(dbURL.path)")
    }

    deinit {
        if let db = db {
            sqlite3_close(db)
        }
    }

    private func execute(sql: String) throws {
        var errMsg: UnsafeMutablePointer<Int8>?
        if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errMsg)
            logger.error("SQL Exec error: \(msg)")
            throw SharedStorageError.queryFailed(msg)
        }
    }

    private func migrateIfNeeded() throws {
        // Create topics, entries, locks, audit tables
        let createTopics = """
        CREATE TABLE IF NOT EXISTS topics (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            ownerUserId TEXT,
            description TEXT,
            acl TEXT,
            createdAt DATETIME DEFAULT CURRENT_TIMESTAMP,
            updatedAt DATETIME DEFAULT CURRENT_TIMESTAMP
        );
        """

        let createEntries = """
        CREATE TABLE IF NOT EXISTS entries (
            id TEXT PRIMARY KEY,
            topicId TEXT NOT NULL,
            key TEXT,
            content TEXT,
            vectors BLOB,
            contentType TEXT,
            createdBy TEXT,
            createdAt DATETIME DEFAULT CURRENT_TIMESTAMP,
            updatedAt DATETIME DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY(topicId) REFERENCES topics(id)
        );
        """

        let createLocks = """
        CREATE TABLE IF NOT EXISTS locks (
            topicId TEXT PRIMARY KEY,
            lockedBy TEXT,
            lockToken TEXT,
            acquiredAt DATETIME,
            ttlSeconds INTEGER
        );
        """

        let createAudit = """
        CREATE TABLE IF NOT EXISTS audit (
            id TEXT PRIMARY KEY,
            topicId TEXT,
            action TEXT,
            performedBy TEXT,
            details TEXT,
            timestamp DATETIME DEFAULT CURRENT_TIMESTAMP
        );
        """

        try execute(sql: createTopics)
        try execute(sql: createEntries)
        try execute(sql: createLocks)
        try execute(sql: createAudit)

        /// Migration: Deduplicate topic names before adding UNIQUE constraint
        /// If duplicate names exist (from previous bug), keep only the oldest one per name.
        /// Note: Conversations referencing deleted duplicate topic IDs will be automatically
        /// reassigned when the user next selects the topic from the picker (which now shows
        /// only unique topics). The UNIQUE index prevents future duplicates.
        let deduplicateTopics = """
        DELETE FROM topics WHERE id IN (
            SELECT t2.id FROM topics t1
            JOIN topics t2 ON t1.name = t2.name AND t1.createdAt < t2.createdAt
        );
        """
        try execute(sql: deduplicateTopics)

        /// Add UNIQUE constraint on topic name to prevent future duplicates
        /// SQLite doesn't support ALTER TABLE ADD CONSTRAINT, so we use CREATE UNIQUE INDEX
        /// IF NOT EXISTS to safely add it on both new and existing databases.
        try execute(sql: "CREATE UNIQUE INDEX IF NOT EXISTS idx_topics_name ON topics(name);")
    }

    // Minimal helper to run simple queries returning no results
    public func runStatement(_ sql: String, params: [String] = []) throws {
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            let err = String(cString: sqlite3_errmsg(db))
            throw SharedStorageError.queryFailed(err)
        }

        // bind params
        for (i, p) in params.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), (p as NSString).utf8String, -1, nil)
        }

        if sqlite3_step(stmt) != SQLITE_DONE {
            let err = String(cString: sqlite3_errmsg(db))
            sqlite3_finalize(stmt)
            throw SharedStorageError.queryFailed(err)
        }

        sqlite3_finalize(stmt)
    }

    /// Run a SELECT query and return rows as array of column->string dictionaries.
    public func queryRows(_ sql: String, params: [String] = []) throws -> [[String: String]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SharedStorageError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }

        for (i, p) in params.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), (p as NSString).utf8String, -1, nil)
        }

        var rows: [[String: String]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let colCount = sqlite3_column_count(stmt)
            var row: [String: String] = [:]
            for i in 0..<colCount {
                if let name = sqlite3_column_name(stmt, i), let c = sqlite3_column_text(stmt, i) {
                    let key = String(cString: name)
                    let value = String(cString: c)
                    row[key] = value
                }
            }
            rows.append(row)
        }

        sqlite3_finalize(stmt)
        return rows
    }

    // MARK: - Lock helpers

    /// Return lock row for topicId or nil if not present
    public func getLockRow(topicId: String) throws -> [String: String]? {
        let rows = try queryRows("SELECT topicId, lockedBy, lockToken, acquiredAt, ttlSeconds FROM locks WHERE topicId = ?", params: [topicId])
        return rows.first
    }

    /// Upsert lock row
    public func upsertLock(topicId: String, lockedBy: String, lockToken: String, acquiredAtISO: String, ttlSeconds: Int) throws {
        let sql = "INSERT OR REPLACE INTO locks (topicId, lockedBy, lockToken, acquiredAt, ttlSeconds) VALUES (?, ?, ?, ?, ?)"
        try runStatement(sql, params: [topicId, lockedBy, lockToken, acquiredAtISO, String(ttlSeconds)])
    }

    /// Delete lock row for topic
    public func deleteLock(topicId: String) throws {
        let sql = "DELETE FROM locks WHERE topicId = ?"
        try runStatement(sql, params: [topicId])
    }

    /// Reclaim stale locks: delete locks where acquiredAt + ttlSeconds < now
    /// Returns number of reclaimed locks
    public func reclaimStaleLocks() throws -> Int {
        // SQLite: compare datetime(acquiredAt, '+' || ttlSeconds || ' seconds') < CURRENT_TIMESTAMP
        let sql = "DELETE FROM locks WHERE datetime(acquiredAt, '+' || ttlSeconds || ' seconds') < CURRENT_TIMESTAMP"
        try runStatement(sql)
        // Not easy to get affected rows from exec helper; query count instead
        let rows = try queryRows("SELECT COUNT(1) as cnt FROM locks WHERE datetime(acquiredAt, '+' || ttlSeconds || ' seconds') < CURRENT_TIMESTAMP")
        if let cntStr = rows.first?["cnt"], let cnt = Int(cntStr) { return cnt }
        return 0
    }

}
