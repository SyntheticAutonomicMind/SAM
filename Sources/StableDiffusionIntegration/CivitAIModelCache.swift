// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

/// Cache for CivitAI model catalog to avoid excessive API requests
public actor CivitAIModelCache {
    private let logger = Logger(label: "CivitAIModelCache")
    private let cacheDirectory: URL
    private let cacheExpiryInterval: TimeInterval = 24 * 60 * 60  /// 24 hours
    
    private struct CachedModelList: Codable {
        let models: [CivitAIModel]
        let timestamp: Date
        let totalCount: Int
    }
    
    public init() {
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        self.cacheDirectory = cachesDir.appendingPathComponent("sam/civitai-cache")
        
        /// Create cache directory if needed
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }
    
    // MARK: - Public API
    
    /// Get cached checkpoint models if available and not expired
    public func getCachedCheckpoints() -> [CivitAIModel]? {
        return getCachedModels(forKey: "checkpoints")
    }
    
    /// Cache checkpoint models
    public func cacheCheckpoints(_ models: [CivitAIModel]) {
        cacheModels(models, forKey: "checkpoints")
    }
    
    /// Get cached LoRA models if available and not expired
    public func getCachedLoRAs() -> [CivitAIModel]? {
        return getCachedModels(forKey: "loras")
    }
    
    /// Cache LoRA models
    public func cacheLoRAs(_ models: [CivitAIModel]) {
        cacheModels(models, forKey: "loras")
    }
    
    /// Clear all cached models
    public func clearCache() {
        do {
            let files = try FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil)
            for file in files {
                try FileManager.default.removeItem(at: file)
            }
            logger.info("Cleared CivitAI model cache")
        } catch {
            logger.error("Failed to clear cache: \(error.localizedDescription)")
        }
    }
    
    /// Check if cache exists and is valid for a given key
    public func isCacheValid(forKey key: String) -> Bool {
        let cacheFile = cacheDirectory.appendingPathComponent("\(key).json")
        
        guard FileManager.default.fileExists(atPath: cacheFile.path) else {
            return false
        }
        
        do {
            let data = try Data(contentsOf: cacheFile)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let cached = try decoder.decode(CachedModelList.self, from: data)
            
            let age = Date().timeIntervalSince(cached.timestamp)
            return age < cacheExpiryInterval
        } catch {
            logger.error("Failed to read cache for \(key): \(error.localizedDescription)")
            return false
        }
    }
    
    // MARK: - Private Helpers
    
    private func getCachedModels(forKey key: String) -> [CivitAIModel]? {
        let cacheFile = cacheDirectory.appendingPathComponent("\(key).json")
        
        guard FileManager.default.fileExists(atPath: cacheFile.path) else {
            logger.debug("No cache file found for \(key)")
            return nil
        }
        
        do {
            let data = try Data(contentsOf: cacheFile)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let cached = try decoder.decode(CachedModelList.self, from: data)
            
            /// Check if cache is still valid
            let age = Date().timeIntervalSince(cached.timestamp)
            if age > cacheExpiryInterval {
                logger.info("Cache for \(key) expired (age: \(Int(age/3600))h)")
                return nil
            }
            
            logger.info("Using cached \(key): \(cached.models.count) models (age: \(Int(age/3600))h)")
            return cached.models
        } catch {
            logger.error("Failed to load cache for \(key): \(error.localizedDescription)")
            return nil
        }
    }
    
    private func cacheModels(_ models: [CivitAIModel], forKey key: String) {
        let cacheFile = cacheDirectory.appendingPathComponent("\(key).json")
        
        let cached = CachedModelList(
            models: models,
            timestamp: Date(),
            totalCount: models.count
        )
        
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(cached)
            try data.write(to: cacheFile)
            logger.info("Cached \(models.count) \(key) to disk")
        } catch {
            logger.error("Failed to cache \(key): \(error.localizedDescription)")
        }
    }
}
