// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Security
import Logging

/// Manages secure storage of secrets using the macOS Keychain.
///
/// Replaces plaintext file storage for sensitive tokens and credentials.
/// Uses the macOS Keychain Services API which provides:
/// - Encryption at rest
/// - Access control via Keychain Access prompts
/// - Per-app sandboxing
/// - Secure enclave support on Apple Silicon
///
/// **Usage:**
/// ```swift
/// let keychain = KeychainManager.shared
///
/// // Store a token
/// try keychain.store(token: "ghp_xxx", for: "github-token")
///
/// // Retrieve a token
/// let token = try keychain.retrieve(for: "github-token")
///
/// // Delete a token
/// try keychain.delete(for: "github-token")
/// ```
public actor KeychainManager {
    public static let shared = KeychainManager()

    private let logger = Logger(label: "com.sam.security.keychain")

    /// Keychain service identifier for SAM tokens.
    private let service = "com.fewtarius.syntheticautonomicmind"

    private init() {}

    // MARK: - Store

    /// Store a secret in the macOS Keychain.
    ///
    /// - Parameters:
    ///   - secret: The secret value to store
    ///   - account: The account/key identifier (e.g., "github-token")
    /// - Throws: KeychainError if storage fails
    public func store(secret: String, for account: String) throws {
        guard let data = secret.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }

        // Delete any existing item first (upsert pattern)
        try? delete(for: account)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)

        guard status == errSecSuccess else {
            logger.error("Failed to store secret for account \(account): OSStatus \(status)")
            throw KeychainError.storeFailed(status: status)
        }

        logger.debug("Stored secret for account: \(account)")
    }

    // MARK: - Retrieve

    /// Retrieve a secret from the macOS Keychain.
    ///
    /// - Parameter account: The account/key identifier
    /// - Returns: The secret value, or nil if not found
    /// - Throws: KeychainError if retrieval fails (other than item not found)
    public func retrieve(for account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let secret = String(data: data, encoding: .utf8) else {
                logger.error("Failed to decode secret for account \(account)")
                throw KeychainError.decodingFailed
            }
            return secret

        case errSecItemNotFound:
            logger.debug("No secret found for account: \(account)")
            return nil

        default:
            logger.error("Failed to retrieve secret for account \(account): OSStatus \(status)")
            throw KeychainError.retrieveFailed(status: status)
        }
    }

    // MARK: - Delete

    /// Delete a secret from the macOS Keychain.
    ///
    /// - Parameter account: The account/key identifier
    /// - Throws: KeychainError if deletion fails (other than item not found)
    public func delete(for account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let status = SecItemDelete(query as CFDictionary)

        switch status {
        case errSecSuccess:
            logger.debug("Deleted secret for account: \(account)")

        case errSecItemNotFound:
            logger.debug("No secret to delete for account: \(account)")

        default:
            logger.error("Failed to delete secret for account \(account): OSStatus \(status)")
            throw KeychainError.deleteFailed(status: status)
        }
    }

    // MARK: - Migration

    /// Migrate a secret from a plaintext file to the Keychain.
    ///
    /// Reads the secret from the specified file, stores it in the Keychain,
    /// and optionally deletes the plaintext file.
    ///
    /// - Parameters:
    ///   - fileURL: Path to the plaintext file containing the secret
    ///   - account: Keychain account to store under
    ///   - deleteFile: Whether to delete the plaintext file after migration (default: true)
    /// - Returns: true if migration occurred, false if file didn't exist or was empty
    public func migrateFromFile(at fileURL: URL, to account: String, deleteFile: Bool = true) throws -> Bool {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return false
        }

        let data = try Data(contentsOf: fileURL)

        // Try to parse as JSON (CopilotTokenStore format)
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // Store each string value as a separate keychain entry
            for (key, value) in json {
                if let stringValue = value as? String {
                    try store(secret: stringValue, for: "\(account).\(key)")
                }
            }
        } else if let content = String(data: data, encoding: .utf8), !content.isEmpty {
            // Plain text file - store as single entry
            try store(secret: content, for: account)
        } else {
            return false
        }

        if deleteFile {
            try FileManager.default.removeItem(at: fileURL)
            logger.info("Migrated and deleted plaintext file: \(fileURL.path)")
        }

        return true
    }
}

// MARK: - Errors

public enum KeychainError: LocalizedError {
    case encodingFailed
    case decodingFailed
    case storeFailed(status: OSStatus)
    case retrieveFailed(status: OSStatus)
    case deleteFailed(status: OSStatus)

    public var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Failed to encode secret as UTF-8 data."
        case .decodingFailed:
            return "Failed to decode secret from Keychain data."
        case .storeFailed(let status):
            return "Failed to store secret in Keychain (OSStatus: \(status))."
        case .retrieveFailed(let status):
            return "Failed to retrieve secret from Keychain (OSStatus: \(status))."
        case .deleteFailed(let status):
            return "Failed to delete secret from Keychain (OSStatus: \(status))."
        }
    }
}