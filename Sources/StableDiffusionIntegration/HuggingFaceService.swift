// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

/// HuggingFace Hub API service for browsing and downloading Stable Diffusion models
public class HuggingFaceService {
    private let logger = Logger(label: "com.sam.sd.huggingface")
    private let baseURL = "https://huggingface.co/api"
    private var apiToken: String?

    public init(apiToken: String? = nil) {
        self.apiToken = apiToken
    }

    /// Update API token
    public func setAPIToken(_ token: String?) {
        self.apiToken = token
    }

    // MARK: - API Methods

    /// Search for Stable Diffusion models
    public func searchModels(
        query: String? = nil,
        filter: String = "stable-diffusion",
        limit: Int = 20,
        sort: String = "downloads",
        direction: String = "-1"
    ) async throws -> [HFModel] {
        var components = URLComponents(string: "\(baseURL)/models")!
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "filter", value: filter),
            URLQueryItem(name: "sort", value: sort),
            URLQueryItem(name: "direction", value: direction),
            URLQueryItem(name: "limit", value: "\(limit)")
        ]

        if let query = query, !query.isEmpty {
            queryItems.append(URLQueryItem(name: "search", value: query))
        }

        components.queryItems = queryItems

        guard let url = components.url else {
            logger.error("Failed to construct URL from components")
            throw HFError.invalidURL
        }

        logger.debug("HuggingFace search URL: \(url.absoluteString)")

        var request = URLRequest(url: url)
        if let apiToken = apiToken {
            request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw HFError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            logger.error("HuggingFace API error - Status \(httpResponse.statusCode)")
            throw HFError.httpError(statusCode: httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        return try decoder.decode([HFModel].self, from: data)
    }

    /// Search for LoRA models specifically
    /// Uses lora tag filtering since HuggingFace doesn't have a dedicated LoRA filter
    public func searchLoRAs(
        query: String? = nil,
        limit: Int = 100,
        sort: String = "downloads",
        direction: String = "-1"
    ) async throws -> [HFModel] {
        var components = URLComponents(string: "\(baseURL)/models")!
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "sort", value: sort),
            URLQueryItem(name: "direction", value: direction),
            URLQueryItem(name: "limit", value: "\(limit)")
        ]

        if let query = query, !query.isEmpty {
            queryItems.append(URLQueryItem(name: "search", value: query))
        }

        /// Use pipeline_tag for text-to-image which includes LoRAs
        queryItems.append(URLQueryItem(name: "pipeline_tag", value: "text-to-image"))

        components.queryItems = queryItems

        guard let url = components.url else {
            logger.error("Failed to construct LoRA search URL")
            throw HFError.invalidURL
        }

        logger.debug("HuggingFace LoRA search URL: \(url.absoluteString)")

        var request = URLRequest(url: url)
        if let apiToken = apiToken {
            request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw HFError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            logger.error("HuggingFace LoRA search error - Status \(httpResponse.statusCode)")
            throw HFError.httpError(statusCode: httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        let allModels = try decoder.decode([HFModel].self, from: data)

        /// Client-side filter: Only return models with 'lora' tag
        let loraModels = allModels.filter { model in
            guard let tags = model.tags else { return false }
            return tags.contains(where: { $0.lowercased().contains("lora") })
        }

        logger.info("Found \(loraModels.count) LoRA models out of \(allModels.count) total")

        return loraModels
    }

    /// Get detailed information about a specific model
    public func getModelDetails(modelId: String) async throws -> HFModel {
        let url = URL(string: "\(baseURL)/models/\(modelId)")!
        var request = URLRequest(url: url)
        if let apiToken = apiToken {
            request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw HFError.invalidResponse
        }

        let decoder = JSONDecoder()
        return try decoder.decode(HFModel.self, from: data)
    }

    /// List files in a model repository
    public func listModelFiles(modelId: String) async throws -> [HFFile] {
        logger.info("listModelFiles called for: \(modelId)")
        /// Use recursive=true to get all files in subdirectories
        let url = URL(string: "\(baseURL)/models/\(modelId)/tree/main?recursive=true")!
        var request = URLRequest(url: url)
        if let apiToken = apiToken {
            request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            logger.error("HTTP error: \(String(describing: (response as? HTTPURLResponse)?.statusCode))")
            throw HFError.invalidResponse
        }

        let decoder = JSONDecoder()
        let files = try decoder.decode([HFFile].self, from: data)
        logger.info("Loaded \(files.count) files for \(modelId)")
        for file in files {
            logger.debug("  File: \(file.path) (CoreML:\(file.isCoreML), ZIP:\(file.isZip), Safetensors:\(file.isSafetensors), Supported:\(file.isSupportedSDFormat))")
        }
        return files
    }

    // MARK: - Hierarchical Download Support

    /// Determine which files to download for a variant model that references a base model
    /// - Parameters:
    ///   - variantModel: The model metadata for the variant
    ///   - variantFiles: All files available in the variant repository
    ///   - baseModel: The model metadata for the base model
    ///   - baseFiles: All files available in the base model repository
    /// - Returns: Tuple of (files to download from variant, files to download from base)
    public func categorizeHierarchicalFiles(
        variantModel: HFModel,
        variantFiles: [HFFile],
        baseModel: HFModel,
        baseFiles: [HFFile]
    ) -> (variantFiles: [HFFile], baseFiles: [HFFile]) {
        logger.info("Categorizing files for hierarchical download")
        logger.info("Variant: \(variantModel.modelId) (\(variantFiles.count) files)")
        logger.info("Base: \(baseModel.modelId) (\(baseFiles.count) files)")

        var filesToDownloadFromVariant: [HFFile] = []
        var filesToDownloadFromBase: [HFFile] = []

        /// Step 1: Identify which components exist in variant
        let variantComponents = Set(variantFiles.compactMap { $0.componentDirectory })
        logger.info("Variant has components: \(variantComponents)")

        /// Step 2: Download all essential files from variant
        for file in variantFiles {
            /// Skip documentation
            guard !file.isDocumentation else { continue }

            /// Include all essential files from variant
            if file.isEssential {
                filesToDownloadFromVariant.append(file)
                logger.debug("From variant: \(file.path)")
            }
        }

        /// Step 3: Download components from base that don't exist in variant
        let baseComponents = ["text_encoder", "text_encoder_2", "vae", "tokenizer", "tokenizer_2",
                              "scheduler", "safety_checker", "feature_extractor"]

        for component in baseComponents {
            /// Skip if variant already has this component
            if variantComponents.contains(component) {
                logger.info("Skipping \(component) from base (exists in variant)")
                continue
            }

            /// Download all files in this component from base
            let componentFiles = baseFiles.filter {
                $0.componentDirectory == component && !$0.isDocumentation
            }

            if !componentFiles.isEmpty {
                filesToDownloadFromBase.append(contentsOf: componentFiles)
                logger.info("From base: \(component)/ (\(componentFiles.count) files)")
            }
        }

        /// Step 4: Download root-level configs from base if not in variant
        let rootConfigs = ["model_index.json", "config.json"]
        for configName in rootConfigs {
            /// Check if variant has it
            let variantHasConfig = variantFiles.contains { $0.path == configName }

            if !variantHasConfig {
                /// Download from base
                if let baseConfig = baseFiles.first(where: { $0.path == configName }) {
                    filesToDownloadFromBase.append(baseConfig)
                    logger.info("From base: \(configName)")
                }
            }
        }

        logger.info("Hierarchical download plan:")
        logger.info("  Variant files: \(filesToDownloadFromVariant.count)")
        logger.info("  Base files: \(filesToDownloadFromBase.count)")
        logger.info("  Total files: \(filesToDownloadFromVariant.count + filesToDownloadFromBase.count)")

        /// Calculate size savings
        let variantSize = filesToDownloadFromVariant.compactMap { $0.fileSize }.reduce(0, +)
        let baseSize = filesToDownloadFromBase.compactMap { $0.fileSize }.reduce(0, +)
        let totalBaseSize = baseFiles.filter { !$0.isDocumentation && $0.isEssential }.compactMap { $0.fileSize }.reduce(0, +)
        let saved = totalBaseSize - baseSize

        logger.info("  Download size: \(formatBytes(variantSize + baseSize))")
        logger.info("  Full base would be: \(formatBytes(totalBaseSize))")
        if saved > 0 {
            let percentage = Double(saved) / Double(totalBaseSize) * 100
            logger.info("  Savings: \(formatBytes(saved)) (\(String(format: "%.1f", percentage))%)")
        }

        return (filesToDownloadFromVariant, filesToDownloadFromBase)
    }

    /// Download a single file from HuggingFace
    /// - Parameters:
    ///   - repoId: Repository ID (e.g., "Tongyi-MAI/Z-Image-Turbo")
    ///   - file: File metadata
    ///   - destination: Local destination URL
    ///   - progress: Progress callback
    /// - Returns: Downloaded file URL
    public func downloadFile(
        repoId: String,
        file: HFFile,
        destination: URL,
        progress: @escaping (Double) -> Void = { _ in }
    ) async throws -> URL {
        /// Construct download URL
        let downloadURL = "https://huggingface.co/\(repoId)/resolve/main/\(file.path)"

        guard let url = URL(string: downloadURL) else {
            throw HFError.invalidURL
        }

        var request = URLRequest(url: url)
        if let apiToken = apiToken {
            request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        }

        /// Create parent directory
        let destinationDir = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)

        /// Use temporary file for atomic download
        let tmpDestination = destination.appendingPathExtension("tmp")
        try? FileManager.default.removeItem(at: tmpDestination)
        try? FileManager.default.removeItem(at: destination)

        logger.info("Downloading: \(file.path) (\(file.fileSize.map { formatBytes($0) } ?? "unknown size"))")

        /// Create download delegate for progress tracking
        let delegate = HFDownloadDelegate(
            destination: tmpDestination,
            progressHandler: progress
        )

        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let task = session.downloadTask(with: request)
        task.resume()

        /// Wait for download to complete
        let downloadedURL = try await withCheckedThrowingContinuation { continuation in
            delegate.completion = continuation
        }

        /// Atomic rename
        try FileManager.default.moveItem(at: downloadedURL, to: destination)

        logger.info("Downloaded: \(file.path) -> \(destination.lastPathComponent)")

        return destination
    }

    /// URLSession delegate for download progress
    private final class HFDownloadDelegate: NSObject, @unchecked Sendable, URLSessionDownloadDelegate {
        let destination: URL
        let progressHandler: (Double) -> Void
        var completion: CheckedContinuation<URL, Error>?

        init(destination: URL, progressHandler: @escaping (Double) -> Void) {
            self.destination = destination
            self.progressHandler = progressHandler
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didWriteData bytesWritten: Int64,
            totalBytesWritten: Int64,
            totalBytesExpectedToWrite: Int64
        ) {
            let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            progressHandler(progress)
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didFinishDownloadingTo location: URL
        ) {
            do {
                try FileManager.default.moveItem(at: location, to: destination)
                completion?.resume(returning: destination)
            } catch {
                completion?.resume(throwing: error)
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error = error {
                completion?.resume(throwing: error)
            }
        }
    }
}

/// Helper to format byte counts
private func formatBytes(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useKB, .useMB, .useGB]
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
}

// MARK: - Error Types

public enum HFError: Error, LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(statusCode: Int)
    case decodingError(Error)
    case fileError(Error)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid HuggingFace URL"
        case .invalidResponse:
            return "Invalid response from HuggingFace API"
        case .httpError(let code):
            return "HuggingFace API error (HTTP \(code))"
        case .decodingError(let error):
            return "Failed to decode HuggingFace response: \(error.localizedDescription)"
        case .fileError(let error):
            return "File operation failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Model Structures

/// HuggingFace model card data
public struct HFCardData: Codable {
    public let base_model: String?
    public let base_model_relation: String?
    public let license: String?
    public let language: [String]?
    public let pipeline_tag: String?
    public let library_name: String?

    enum CodingKeys: String, CodingKey {
        case base_model
        case base_model_relation
        case license
        case language
        case pipeline_tag
        case library_name
    }
}

/// HuggingFace model
public struct HFModel: Codable, Identifiable {
    public let id: String
    public let modelId: String
    public let author: String?
    public let lastModified: String?
    public let `private`: Bool?
    public let downloads: Int?
    public let likes: Int?
    public let tags: [String]?
    public let pipeline_tag: String?
    public let library_name: String?
    public let cardData: HFCardData?

    enum CodingKeys: String, CodingKey {
        case id
        case modelId
        case author
        case lastModified
        case `private`
        case downloads
        case likes
        case tags
        case pipeline_tag
        case library_name
        case cardData
    }

    /// Display name (last component of modelId)
    public var displayName: String {
        modelId.components(separatedBy: "/").last ?? modelId
    }

    /// Username/organization (first component of modelId)
    public var username: String {
        modelId.components(separatedBy: "/").first ?? ""
    }

    /// Detect if this model references a base model
    public var baseModelId: String? {
        // Priority 1: cardData.base_model (most reliable)
        if let baseModel = cardData?.base_model {
            return baseModel
        }

        // Priority 2: tags with "base_model:" prefix
        if let tags = tags {
            for tag in tags where tag.hasPrefix("base_model:") {
                let parts = tag.split(separator: ":")
                // Format: "base_model:ModelId" or "base_model:relation:ModelId"
                if parts.count >= 2 {
                    let modelPart = parts.count > 2 ? String(parts[2]) : String(parts[1])
                    return modelPart
                }
            }
        }

        return nil
    }

    /// Get base model relation type (quantized, lora, finetune, etc.)
    public var baseModelRelation: String? {
        return cardData?.base_model_relation
    }

    /// Check if this is a model variant (has a base model)
    public var isVariant: Bool {
        return baseModelId != nil
    }
}

/// HuggingFace file
public struct HFFile: Codable, Identifiable {
    public let path: String
    public let type: String
    public let size: Int?
    public let lfs: HFLFS?

    public var id: String { path }

    /// Check if file is a safetensors file
    public var isSafetensors: Bool {
        path.hasSuffix(".safetensors")
    }

    /// Check if file is a CoreML model package
    public var isCoreML: Bool {
        path.hasSuffix(".mlmodelc") || path.hasSuffix(".mlpackage")
    }

    /// Check if file is a ZIP archive (may contain CoreML models)
    public var isZip: Bool {
        path.hasSuffix(".zip")
    }

    /// Check if file is a supported Stable Diffusion format
    public var isSupportedSDFormat: Bool {
        isSafetensors || isCoreML || isZip
    }

    /// Get file size (prefer LFS size if available)
    public var fileSize: Int64? {
        if let lfsSize = lfs?.size {
            return Int64(lfsSize)
        } else if let size = size {
            return Int64(size)
        }
        return nil
    }

    /// Check if file is in a model component directory (text_encoder, vae, etc.)
    public var componentDirectory: String? {
        let components = ["text_encoder", "text_encoder_2", "vae", "tokenizer", "tokenizer_2",
                          "scheduler", "transformer", "unet", "safety_checker", "feature_extractor"]
        for component in components {
            if path.hasPrefix("\(component)/") {
                return component
            }
        }
        return nil
    }

    /// Check if file is a configuration file
    public var isConfig: Bool {
        let filename = (path as NSString).lastPathComponent
        return filename.hasSuffix(".json") || filename.hasSuffix(".txt")
    }

    /// Check if file is documentation/assets (can be skipped)
    public var isDocumentation: Bool {
        return path.hasPrefix("assets/") ||
               path.hasPrefix("docs/") ||
               path.hasSuffix(".md") ||
               path.hasSuffix(".pdf") ||
               path.hasSuffix(".png") ||
               path.hasSuffix(".jpg") ||
               path.hasSuffix(".jpeg") ||
               path.hasSuffix(".webp") ||
               path.hasSuffix(".gif")
    }

    /// Check if file is essential for model operation
    public var isEssential: Bool {
        // Model weights
        if isSafetensors || isCoreML {
            return true
        }

        // Root-level configs
        let filename = (path as NSString).lastPathComponent
        if !path.contains("/") && (filename == "model_index.json" || filename == "config.json") {
            return true
        }

        // Component directories
        if componentDirectory != nil {
            return true
        }

        return false
    }
}

/// HuggingFace Large File Storage metadata
public struct HFLFS: Codable {
    public let oid: String
    public let size: Int
    public let pointerSize: Int
}
