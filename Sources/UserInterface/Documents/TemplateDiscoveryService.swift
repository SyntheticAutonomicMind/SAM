// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

/// Represents a document template that can be used for generation
public struct DocumentTemplate: Codable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let path: URL
    public let format: String  // "pptx", "docx", etc.
    public let source: TemplateSource

    public enum TemplateSource: String, Codable {
        case office = "Microsoft Office"
        case user = "User Templates"
        case web = "Downloaded"
        case system = "System"
    }

    public init(id: String = UUID().uuidString, name: String, path: URL, format: String, source: TemplateSource) {
        self.id = id
        self.name = name
        self.path = path
        self.format = format
        self.source = source
    }
}

/// Service for discovering and managing document templates
public class TemplateDiscoveryService {
    private let logger = Logger(label: "com.sam.templates")
    private let cacheDir: URL

    public init() {
        let cache = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("sam/templates")

        self.cacheDir = cache

        // Create cache directory if needed
        try? FileManager.default.createDirectory(
            at: cache,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    /// Discover all available templates for a specific format
    /// - Parameter format: The document format (e.g., "pptx", "docx")
    /// - Returns: Array of discovered templates
    public func discoverTemplates(format: String = "pptx") -> [DocumentTemplate] {
        logger.debug("Discovering templates for format: \(format)")

        var templates: [DocumentTemplate] = []

        // Check Office installation
        templates.append(contentsOf: findOfficeTemplates(format: format))

        // Check user templates
        templates.append(contentsOf: findUserTemplates(format: format))

        // Check cached web templates
        templates.append(contentsOf: findCachedTemplates(format: format))

        logger.info("Discovered \(templates.count) templates for \(format)")
        return templates
    }

    /// Find templates in Microsoft Office installation
    private func findOfficeTemplates(format: String) -> [DocumentTemplate] {
        var templates: [DocumentTemplate] = []

        // PowerPoint templates
        if format == "pptx" {
            let officePaths = [
                "/Applications/Microsoft PowerPoint.app/Contents/Resources/Templates/",
                "/Applications/Microsoft PowerPoint.app/Contents/Resources/DLC/Templates/"
            ]

            for path in officePaths {
                if FileManager.default.fileExists(atPath: path) {
                    templates.append(contentsOf: scanDirectory(
                        URL(fileURLWithPath: path),
                        format: format,
                        source: .office
                    ))
                }
            }
        }

        // Word templates
        if format == "docx" {
            let officeWordPath = "/Applications/Microsoft Word.app/Contents/Resources/Templates/"
            if FileManager.default.fileExists(atPath: officeWordPath) {
                templates.append(contentsOf: scanDirectory(
                    URL(fileURLWithPath: officeWordPath),
                    format: format,
                    source: .office
                ))
            }
        }

        if templates.isEmpty {
            logger.debug("Office not installed or no templates found")
        } else {
            logger.info("Found \(templates.count) Office templates")
        }

        return templates
    }

    /// Find user-created templates
    private func findUserTemplates(format: String) -> [DocumentTemplate] {
        let userPaths = [
            "~/Library/Application Support/Microsoft/Office/User Templates/",
            "~/Documents/Templates/",
            "~/Library/Application Support/SAM/Templates/"
        ]

        var templates: [DocumentTemplate] = []

        for pathString in userPaths {
            let expandedPath = NSString(string: pathString).expandingTildeInPath
            let url = URL(fileURLWithPath: expandedPath)

            if FileManager.default.fileExists(atPath: url.path) {
                templates.append(contentsOf: scanDirectory(
                    url,
                    format: format,
                    source: .user
                ))
            }
        }

        if !templates.isEmpty {
            logger.info("Found \(templates.count) user templates")
        }

        return templates
    }

    /// Find templates in cache directory
    private func findCachedTemplates(format: String) -> [DocumentTemplate] {
        guard FileManager.default.fileExists(atPath: cacheDir.path) else {
            return []
        }

        let templates = scanDirectory(cacheDir, format: format, source: .web)

        if !templates.isEmpty {
            logger.info("Found \(templates.count) cached templates")
        }

        return templates
    }

    /// Scan a directory for template files
    private func scanDirectory(_ url: URL, format: String, source: DocumentTemplate.TemplateSource) -> [DocumentTemplate] {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var templates: [DocumentTemplate] = []

        for case let fileURL as URL in enumerator {
            // Check if it's a regular file
            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                  resourceValues.isRegularFile == true else {
                continue
            }

            // Check file extension
            if fileURL.pathExtension.lowercased() == format.lowercased() {
                let name = fileURL.deletingPathExtension().lastPathComponent
                templates.append(DocumentTemplate(
                    name: name,
                    path: fileURL,
                    format: format,
                    source: source
                ))
            }
        }

        return templates
    }

    /// Download a template from a URL
    /// - Parameter url: The URL to download from
    /// - Returns: The downloaded template
    public func downloadTemplate(from url: URL) async throws -> DocumentTemplate {
        logger.info("Downloading template from: \(url.absoluteString)")

        // Download to cache directory
        let filename = url.lastPathComponent
        let destinationURL = cacheDir.appendingPathComponent(filename)

        // Download file
        let (tempURL, response) = try await URLSession.shared.download(from: url)

        // Validate response
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw TemplateError.downloadFailed("HTTP error")
        }

        // Move to cache directory
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }

        try FileManager.default.moveItem(at: tempURL, to: destinationURL)

        logger.info("Downloaded template: \(destinationURL.lastPathComponent)")

        return DocumentTemplate(
            name: destinationURL.deletingPathExtension().lastPathComponent,
            path: destinationURL,
            format: destinationURL.pathExtension,
            source: .web
        )
    }

    /// Delete a cached template
    /// - Parameter template: The template to delete
    public func deleteTemplate(_ template: DocumentTemplate) throws {
        guard template.source == .web || template.source == .user else {
            throw TemplateError.cannotDelete("Cannot delete system or Office templates")
        }

        try FileManager.default.removeItem(at: template.path)
        logger.info("Deleted template: \(template.name)")
    }
}

// MARK: - Error Types

public enum TemplateError: Error, LocalizedError {
    case downloadFailed(String)
    case cannotDelete(String)
    case notFound(String)

    public var errorDescription: String? {
        switch self {
        case .downloadFailed(let message):
            return "Template download failed: \(message)"
        case .cannotDelete(let message):
            return "Cannot delete template: \(message)"
        case .notFound(let message):
            return "Template not found: \(message)"
        }
    }
}
