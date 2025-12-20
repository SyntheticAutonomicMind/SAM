// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Vapor

// MARK: - Model Download API Structures

/// Request to start downloading a model.
public struct ModelDownloadRequest: Content {
    public let repoId: String
    public let filename: String

    public init(repoId: String, filename: String) {
        self.repoId = repoId
        self.filename = filename
    }
}

/// Response when starting a model download.
public struct ModelDownloadResponse: Content {
    public let downloadId: String
    public let repoId: String
    public let filename: String
    public let status: String

    public init(downloadId: String, repoId: String, filename: String, status: String) {
        self.downloadId = downloadId
        self.repoId = repoId
        self.filename = filename
        self.status = status
    }
}

/// Download progress status response.
public struct ModelDownloadStatus: Content {
    public let downloadId: String
    public let status: String
    public let progress: Double
    public let bytesDownloaded: Int64?
    public let totalBytes: Int64?
    public let downloadSpeed: Double?
    public let eta: Double?
    public let error: String?

    public init(
        downloadId: String,
        status: String,
        progress: Double,
        bytesDownloaded: Int64? = nil,
        totalBytes: Int64? = nil,
        downloadSpeed: Double? = nil,
        eta: Double? = nil,
        error: String? = nil
    ) {
        self.downloadId = downloadId
        self.status = status
        self.progress = progress
        self.bytesDownloaded = bytesDownloaded
        self.totalBytes = totalBytes
        self.downloadSpeed = downloadSpeed
        self.eta = eta
        self.error = error
    }
}

/// List of installed models.
public struct InstalledModelsResponse: Content {
    public let models: [InstalledModelInfo]

    public init(models: [InstalledModelInfo]) {
        self.models = models
    }
}

/// Information about an installed model.
public struct InstalledModelInfo: Content {
    public let id: String
    public let name: String
    public let provider: String
    public let path: String
    public let sizeBytes: Int64?
    public let quantization: String?

    public init(id: String, name: String, provider: String, path: String, sizeBytes: Int64?, quantization: String?) {
        self.id = id
        self.name = name
        self.provider = provider
        self.path = path
        self.sizeBytes = sizeBytes
        self.quantization = quantization
    }
}

/// Cancel download response.
public struct ModelDownloadCancelResponse: Content {
    public let downloadId: String
    public let status: String
    public let message: String

    public init(downloadId: String, status: String, message: String) {
        self.downloadId = downloadId
        self.status = status
        self.message = message
    }
}
