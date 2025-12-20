// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import AppKit
import Logging

/// Exports Mermaid diagrams as PNG or SVG images for embedding in documents
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
    /// - Parameters:
    ///   - code: The Mermaid diagram code to render
    ///   - format: The output format (PNG or SVG)
    ///   - size: The desired size for rendering (default: 800x600)
    ///   - outputPath: The URL where the image should be saved
    /// - Returns: The URL of the exported image file
    public func exportDiagram(
        _ code: String,
        format: ExportFormat,
        size: CGSize = CGSize(width: 800, height: 600),
        outputPath: URL
    ) throws -> URL {
        logger.debug("Exporting Mermaid diagram: format=\(format), size=\(size)")

        // 1. Validate diagram code
        let parser = MermaidParser()
        let diagram = parser.parse(code)

        // Check if diagram is supported
        if case .unsupported = diagram {
            logger.error("Attempted to export unsupported diagram type")
            throw ExportError.invalidDiagramCode
        }

        // 2. Render to NSImage on the main thread (SwiftUI requirement)
        var image: NSImage?
        var renderError: Error?

        if Thread.isMainThread {
            image = MainActor.assumeIsolated {
                MermaidImageRenderer.renderDiagram(code: code, width: size.width)
            }
        } else {
            // Dispatch to main thread and wait
            DispatchQueue.main.sync {
                image = MainActor.assumeIsolated {
                    MermaidImageRenderer.renderDiagram(code: code, width: size.width)
                }
            }
        }

        guard let renderedImage = image else {
            logger.error("Failed to render Mermaid diagram to NSImage")
            throw ExportError.renderingFailed
        }

        logger.debug("Successfully rendered diagram to NSImage: \(renderedImage.size)")

        // 3. Export based on format
        switch format {
        case .png:
            return try exportPNG(image: renderedImage, to: outputPath)
        case .svg:
            // SVG export would require vector path generation
            // For now, we only support PNG
            logger.warning("SVG export requested but not yet implemented")
            throw ExportError.unsupportedFormat
        }
    }

    /// Export NSImage as PNG file
    private func exportPNG(image: NSImage, to path: URL) throws -> URL {
        logger.debug("Converting NSImage to PNG format")

        // Convert NSImage to PNG data
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            logger.error("Failed to convert NSImage to PNG data")
            throw ExportError.conversionFailed
        }

        // Write to file
        do {
            try pngData.write(to: path)
            logger.info("Exported PNG diagram to \(path.path)")
            return path
        } catch {
            logger.error("Failed to write PNG file: \(error.localizedDescription)")
            throw ExportError.conversionFailed
        }
    }

    /// Export diagram with auto-generated filename in temporary directory
    /// - Parameters:
    ///   - code: The Mermaid diagram code to render
    ///   - format: The output format (PNG or SVG)
    ///   - size: The desired size for rendering
    /// - Returns: The URL of the exported image file
    public func exportDiagramToTemp(
        _ code: String,
        format: ExportFormat = .png,
        size: CGSize = CGSize(width: 800, height: 600)
    ) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let filename = "mermaid_\(UUID().uuidString).png"
        let outputURL = tempDir.appendingPathComponent(filename)

        return try exportDiagram(code, format: format, size: size, outputPath: outputURL)
    }
}
