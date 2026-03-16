// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import AppKit
import Logging

/// Exports Mermaid diagrams as PNG or SVG images for embedding in documents.
/// Uses bundled mermaid.js for full diagram type support.
public class MermaidDiagramExporter {
    private let logger = Logger(label: "com.sam.mermaid.exporter")

    public enum ExportFormat {
        case png
        case svg
    }

    public enum ExportError: Error, LocalizedError {
        case renderingFailed
        case conversionFailed
        case unsupportedFormat
        case invalidDiagramCode

        public var errorDescription: String? {
            switch self {
            case .renderingFailed:
                return "Failed to render diagram to image"
            case .conversionFailed:
                return "Failed to convert image to target format"
            case .unsupportedFormat:
                return "SVG export not yet implemented. Use PNG format."
            case .invalidDiagramCode:
                return "Invalid or unsupported Mermaid diagram code"
            }
        }
    }

    /// Export Mermaid diagram code to image file
    @MainActor
    public func exportDiagram(
        _ code: String,
        format: ExportFormat,
        size: CGSize = CGSize(width: 800, height: 600),
        outputPath: URL
    ) async throws -> URL {
        logger.debug("Exporting Mermaid diagram: format=\(format), size=\(size)")

        // Render to NSImage via mermaid.js
        let image = await MermaidImageRenderer.renderDiagram(code: code, width: size.width)

        guard let renderedImage = image else {
            logger.error("Failed to render Mermaid diagram to NSImage")
            throw ExportError.renderingFailed
        }

        logger.debug("Rendered diagram: \(renderedImage.size)")

        switch format {
        case .png:
            return try exportPNG(image: renderedImage, to: outputPath)
        case .svg:
            logger.warning("SVG export requested but not yet implemented")
            throw ExportError.unsupportedFormat
        }
    }

    private func exportPNG(image: NSImage, to path: URL) throws -> URL {
        logger.debug("Converting to PNG format")

        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            logger.error("Failed to convert to PNG data")
            throw ExportError.conversionFailed
        }

        do {
            try pngData.write(to: path)
            logger.info("Exported PNG: \(path.path)")
            return path
        } catch {
            logger.error("Failed to write PNG: \(error.localizedDescription)")
            throw ExportError.conversionFailed
        }
    }

    /// Export diagram with auto-generated filename in temporary directory
    @MainActor
    public func exportDiagramToTemp(
        _ code: String,
        format: ExportFormat = .png,
        size: CGSize = CGSize(width: 800, height: 600)
    ) async throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let filename = "mermaid_\(UUID().uuidString).png"
        let outputURL = tempDir.appendingPathComponent(filename)

        return try await exportDiagram(code, format: format, size: size, outputPath: outputURL)
    }
}
