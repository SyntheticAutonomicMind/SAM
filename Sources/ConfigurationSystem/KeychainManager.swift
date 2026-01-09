// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Security
import Logging

/// Secure storage manager for API tokens and sensitive data using macOS Keychain.
/// 
/// This manager provides a safe way to store sensitive information like API tokens
/// using the system's Keychain Services, ensuring data is encrypted and protected
/// by the operating system's security mechanisms.
///
/// **Example Usage:**
/// ```swift
/// // Store a token
/// try KeychainManager.store("my-secret-token", for: "apiToken")
///
/// // Retrieve a token
/// let token = try KeychainManager.retrieve("apiToken")
///
/// // Delete a token
/// try KeychainManager.delete("apiToken")
/// ```
public class KeychainManager {
    private static let logger = Logger(label: "com.sam.keychain")
    private static let serviceName = "com.fewtarius.syntheticautonomicmind.api"
    
    /// Store a value securely in the Keychain.
    ///
    /// - Parameters:
    ///   - value: The string value to store
    ///   - key: The key to associate with the value
    /// - Throws: `KeychainError.unableToStore` if the operation fails
    public static func store(_ value: String, for key: String) throws {
        guard let data = value.data(using: .utf8) else {
            logger.error("Failed to encode value as UTF-8 for key: \(key)")
            throw KeychainError.unableToStore
        }
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecValueData as String: data
        ]
        
        // Delete existing item if it exists
        SecItemDelete(query as CFDictionary)
        
        // Add new item
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            logger.error("Failed to store value in Keychain for key: \(key), status: \(status)")
            throw KeychainError.unableToStore
        }
        
        logger.info("Successfully stored value in Keychain for key: \(key)")
    }
    
    /// Retrieve a value from the Keychain.
    ///
    /// - Parameter key: The key associated with the value
    /// - Returns: The stored string value
    /// - Throws: `KeychainError.unableToRetrieve` if the value doesn't exist or can't be retrieved
    public static func retrieve(_ key: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            logger.debug("Failed to retrieve value from Keychain for key: \(key), status: \(status)")
            throw KeychainError.unableToRetrieve
        }
        
        logger.debug("Successfully retrieved value from Keychain for key: \(key)")
        return value
    }
    
    /// Delete a value from the Keychain.
    ///
    /// - Parameter key: The key associated with the value to delete
    /// - Throws: `KeychainError.unableToDelete` if the operation fails
    public static func delete(_ key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            logger.error("Failed to delete value from Keychain for key: \(key), status: \(status)")
            throw KeychainError.unableToDelete
        }
        
        logger.info("Successfully deleted value from Keychain for key: \(key)")
    }
    
    /// Check if a value exists in the Keychain without retrieving it.
    ///
    /// - Parameter key: The key to check
    /// - Returns: `true` if the value exists, `false` otherwise
    public static func exists(_ key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecReturnData as String: false
        ]
        
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }
    
    /// Errors that can occur during Keychain operations.
    public enum KeychainError: LocalizedError {
        case unableToStore
        case unableToRetrieve
        case unableToDelete
        
        public var errorDescription: String? {
            switch self {
            case .unableToStore:
                return "Failed to store value in Keychain"
            case .unableToRetrieve:
                return "Failed to retrieve value from Keychain"
            case .unableToDelete:
                return "Failed to delete value from Keychain"
            }
        }
    }
}
