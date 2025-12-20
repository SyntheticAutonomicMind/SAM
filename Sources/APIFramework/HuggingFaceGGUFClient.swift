// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

private let hfLogger = Logger(label: "com.sam.huggingface.GGUFClient")

/// HuggingFace API Client for GGUF and MLX model discovery and downloading Supports searching, fetching model info, and downloading with progress tracking.
@MainActor
public class HuggingFaceGGUFClient {
    private let baseURL = "https://huggingface.co"
    private let apiURL = "https://huggingface.co/api"
    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config)
    }

    // MARK: - Model Search

    /// Search HuggingFace for GGUF and MLX compatible models - Parameters: - query: Search query string - limit: Maximum number of results - fileExtension: Optional file extension filter (.gguf or .safetensors for MLX).
    @MainActor
    public func searchModels(query: String, limit: Int = 20, fileExtension: String? = nil) async throws -> [HFModel] {
        hfLogger.debug("searchModels called: query='\(query)', limit=\(limit), ext=\(fileExtension ?? "nil")")

        var components = URLComponents(string: "\(apiURL)/models")!
        var queryItems: [URLQueryItem] = []

        if !query.isEmpty {
            queryItems.append(URLQueryItem(name: "search", value: query))
        }

        /// Add file extension filter if specified
        /// - .gguf → filter=gguf (GGUF models)
        /// - .safetensors → no filter, search by query (MLX models)
        /// - .coreml → filter=coreml (CoreML/SD models)
        /// - nil → filter=gguf (default for backward compatibility)
        if let ext = fileExtension {
            if ext == ".gguf" {
                queryItems.append(URLQueryItem(name: "filter", value: "gguf"))
            } else if ext == ".safetensors" {
                /// MLX models don't have a direct filter, rely on model names/tags containing "mlx"
                hfLogger.debug("Searching for MLX models (safetensors) - using query string matching")
            } else if ext == ".coreml" {
                /// CoreML/Stable Diffusion models
                hfLogger.debug("Using filter=coreml for SD models")
                queryItems.append(URLQueryItem(name: "filter", value: "coreml"))
            } else {
                let filterValue = ext.trimmingCharacters(in: CharacterSet(charactersIn: "."))
                queryItems.append(URLQueryItem(name: "filter", value: filterValue))
            }
        } else {
            /// Default to GGUF for backward compatibility (most SAM models are GGUF)
            queryItems.append(URLQueryItem(name: "filter", value: "gguf"))
        }

        queryItems.append(URLQueryItem(name: "limit", value: String(limit)))
        queryItems.append(URLQueryItem(name: "sort", value: "downloads"))
        queryItems.append(URLQueryItem(name: "direction", value: "-1"))

        components.queryItems = queryItems

        guard let url = components.url else {
            hfLogger.error("Invalid URL for HuggingFace API request")
            throw HFError.invalidURL
        }

        hfLogger.debug("Requesting URL: \(url.absoluteString)")

        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            hfLogger.error("Invalid HTTP response from HuggingFace API")
            throw HFError.invalidResponse
        }

        hfLogger.debug("HTTP status code: \(httpResponse.statusCode)")

        guard httpResponse.statusCode == 200 else {
            hfLogger.error("HuggingFace API returned status code: \(httpResponse.statusCode)")
            if let responseBody = String(data: data, encoding: .utf8) {
                hfLogger.debug("Response body: \(responseBody)")
            }
            throw HFError.apiError(httpResponse.statusCode, "API request failed")
        }

        hfLogger.debug("Response data size: \(data.count) bytes")

        let models = try JSONDecoder().decode([HFModel].self, from: data)
        hfLogger.debug("Decoded \(models.count) models from response")

        /// Log first few model IDs.
        if !models.isEmpty {
            let modelIds = models.prefix(5).map { $0.id }.joined(separator: ", ")
            hfLogger.debug("Sample models: \(modelIds)")
        }

        return models
    }

    /// Get detailed information about a specific model.
    public func getModelInfo(repoId: String) async throws -> HFModel {
        hfLogger.info("Fetching model info for: \(repoId)")

        let urlString = "\(apiURL)/models/\(repoId)"
        guard let url = URL(string: urlString) else {
            throw HFError.invalidURL
        }

        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw HFError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            throw HFError.apiError(httpResponse.statusCode, "Model not found")
        }

        let model = try JSONDecoder().decode(HFModel.self, from: data)
        hfLogger.info("Retrieved model info for: \(model.id)")

        return model
    }

    // MARK: - Model Download

    /// Download a model file with progress tracking.
    @MainActor
    public func downloadModel(
        repoId: String,
        filename: String,
        destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        hfLogger.debug("Downloading model file: \(filename) from \(repoId)")

        /// Create parent directories.
        let parentDir = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        /// Build download URL.
        let downloadURL = "\(baseURL)/\(repoId)/resolve/main/\(filename)"
        guard let url = URL(string: downloadURL) else {
            throw HFError.invalidURL
        }

        /// Create download task with progress tracking using traditional delegate pattern CRITICAL: Must use downloadTask(with:) WITHOUT completion handler If you provide a completion handler, delegate methods are NOT called!.
        return try await withCheckedThrowingContinuation { continuation in
            let delegate = DownloadDelegate(
                progress: progress,
                destination: destination,
                continuation: continuation
            )
            let delegateSession = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)

            /// Use downloadTask WITHOUT completion handler - this allows delegate methods to be called.
            let downloadTask = delegateSession.downloadTask(with: url)
            delegate.setDownloadTask(downloadTask)
            downloadTask.resume()
            hfLogger.info("Download task started for: \(filename)")
        }
    }

    /// Create a cancellable download that can be stopped.
    public func downloadModelCancellable(
        repoId: String,
        filename: String,
        destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) -> (task: Task<URL, Error>, cancel: () -> Void) {
        var delegateRef: DownloadDelegate?

        let task = Task {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                let delegate = DownloadDelegate(
                    progress: progress,
                    destination: destination,
                    continuation: continuation
                )
                delegateRef = delegate

                let delegateSession = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
                let downloadTask = delegateSession.downloadTask(with: URL(string: "\(baseURL)/\(repoId)/resolve/main/\(filename)")!)
                delegate.setDownloadTask(downloadTask)
                downloadTask.resume()
            }
        }

        let cancel: () -> Void = {
            if let delegate = delegateRef {
                delegate.cancel()
            }
        }

        return (task, cancel)
    }
}

// MARK: - Supporting Types

public struct HFModel: Codable, Identifiable {
    public let id: String
    public let modelId: String?
    public let author: String?
    public let sha: String?
    public let lastModified: String?
    public let isPrivate: Bool?
    public let gated: Bool?
    public let disabled: Bool?
    public let downloads: Int?
    public let likes: Int?
    public let tags: [String]?
    public let pipelineTag: String?
    public let libraryName: String?
    public let siblings: [HFModelFile]?

    enum CodingKeys: String, CodingKey {
        case id = "id"
        case modelId = "modelId"
        case author = "author"
        case sha = "sha"
        case lastModified = "lastModified"
        case isPrivate = "private"
        case gated = "gated"
        case disabled = "disabled"
        case downloads = "downloads"
        case likes = "likes"
        case tags = "tags"
        case pipelineTag = "pipeline_tag"
        case libraryName = "library_name"
        case siblings = "siblings"
    }

    /// Get displayable model name.
    public var displayName: String {
        return modelId ?? id
    }

    /// Get author name.
    public var authorName: String {
        return author ?? id.components(separatedBy: "/").first ?? "Unknown"
    }

    /// Get all GGUF files from siblings.
    public var ggufFiles: [HFModelFile] {
        guard let siblings = siblings else { return [] }
        return siblings.filter { $0.rfilename.hasSuffix(".gguf") }
    }

    /// Get all MLX files from siblings.
    public var mlxFiles: [HFModelFile] {
        guard let siblings = siblings else { return [] }
        return siblings.filter {
            $0.rfilename.hasSuffix(".safetensors") ||
            $0.rfilename.hasSuffix(".mlx")
        }
    }

    /// Check if model has GGUF format For search results (no siblings), check tags.
    public var hasGGUF: Bool {
        if let siblings = siblings, !siblings.isEmpty {
            return !ggufFiles.isEmpty
        }
        /// Fallback for search results: check tags.
        return tags?.contains { $0.lowercased() == "gguf" } == true
    }

    /// Check if model has MLX format.
    public var hasMLX: Bool {
        if let siblings = siblings, !siblings.isEmpty {
            return !mlxFiles.isEmpty
        }
        /// Fallback for search results: check tags.
        return tags?.contains { $0.lowercased().contains("mlx") } == true
    }
}

public struct HFModelFile: Codable, Identifiable {
    public let rfilename: String
    public let size: Int64?

    public var id: String { rfilename }

    enum CodingKeys: String, CodingKey {
        case rfilename = "rfilename"
        case size = "size"
    }

    /// Extract quantization from filename (e.g., Q4_K_M, Q5_0, etc.).
    public var quantization: String? {
        let pattern = "Q\\d+_[KM0-9_]+"
        if let range = rfilename.range(of: pattern, options: .regularExpression) {
            return String(rfilename[range])
        }
        return nil
    }

    /// Format file size for display.
    public var sizeFormatted: String? {
        guard let bytes = size else { return nil }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    /// Get file extension.
    public var fileExtension: String {
        return (rfilename as NSString).pathExtension.lowercased()
    }

    /// Check if this is a GGUF file.
    public var isGGUF: Bool {
        return fileExtension == "gguf"
    }

    /// Check if this is an MLX file.
    public var isMLX: Bool {
        return fileExtension == "safetensors" || fileExtension == "mlx"
    }
}

public enum HFError: LocalizedError {
    case invalidURL
    case invalidResponse
    case apiError(Int, String)
    case downloadError(String)
    case networkError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL"

        case .invalidResponse:
            return "Invalid response from server"

        case .apiError(let code, let message):
            return "API Error (\(code)): \(message)"

        case .downloadError(let message):
            return "Download failed: \(message)"

        case .networkError(let message):
            return "Network error: \(message)"
        }
    }
}

// MARK: - Protocol Conformance

private final class DownloadDelegate: NSObject, @unchecked Sendable, URLSessionDownloadDelegate {
    private let progress: @Sendable (Double) -> Void
    private let destination: URL
    private let continuation: CheckedContinuation<URL, Error>
    private var lastLoggedPercent: Int = -1
    private var hasResumed = false
    private var downloadTask: URLSessionDownloadTask?

    init(
        progress: @escaping @Sendable (Double) -> Void,
        destination: URL,
        continuation: CheckedContinuation<URL, Error>
    ) {
        self.progress = progress
        self.destination = destination
        self.continuation = continuation
        super.init()
        hfLogger.info("DownloadDelegate initialized")
    }

    func setDownloadTask(_ task: URLSessionDownloadTask) {
        self.downloadTask = task
    }

    func cancel() {
        hfLogger.info("Cancelling download task")
        downloadTask?.cancel()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else {
            hfLogger.warning("totalBytesExpectedToWrite is 0 or negative")
            return
        }

        let progressValue = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)

        /// Log progress every 10%.
        let percent = Int(progressValue * 100)
        if percent >= lastLoggedPercent + 10 {
            lastLoggedPercent = percent
            hfLogger.info("Download progress: \(percent)% (\(totalBytesWritten)/\(totalBytesExpectedToWrite) bytes)")
        }

        progress(progressValue)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        hfLogger.info("Download finished, moving file to destination: \(destination.path)")
        progress(1.0)

        guard !hasResumed else {
            hfLogger.warning("Continuation already resumed, ignoring didFinishDownloadingTo")
            return
        }

        do {
            /// Move to final destination.
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)

            hfLogger.debug("Successfully downloaded to: \(destination.path)")
            hasResumed = true
            continuation.resume(returning: destination)
        } catch {
            hfLogger.error("Failed to move downloaded file: \(error.localizedDescription)")
            hasResumed = true
            continuation.resume(throwing: error)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        hfLogger.info("Task completed with error: \(error?.localizedDescription ?? "none")")

        guard !hasResumed else {
            hfLogger.info("Continuation already resumed, ignoring didCompleteWithError")
            return
        }

        if let error = error {
            hfLogger.error("Download failed: \(error.localizedDescription)")
            hasResumed = true
            continuation.resume(throwing: HFError.downloadError(error.localizedDescription))
        }
        /// If no error, didFinishDownloadingTo should have already resumed the continuation.
    }
}
