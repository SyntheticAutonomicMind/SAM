// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

/// Generator for PowerPoint presentations from markdown content
public class PPTXGenerator {
    private let logger = Logger(label: "com.sam.pptx")
    private let scriptPath: String
    private let pythonPath: String

    public init() {
        // Determine paths to bundled Python and script
        if let bundlePath = Bundle.main.resourcePath {
            // Production: Use bundled Python environment
            self.pythonPath = "\(bundlePath)/python_env/bin/python3"
            self.scriptPath = "\(bundlePath)/generate_pptx.py"
        } else {
            // Development fallback
            self.pythonPath = "/usr/bin/python3"
            self.scriptPath = "scripts/generate_pptx.py"
        }

        logger.debug("Python path: \(pythonPath)")
        logger.debug("Script path: \(scriptPath)")
    }

    /// Generate PowerPoint presentation from markdown content
    /// - Parameters:
    ///   - markdown: The markdown content to convert
    ///   - outputPath: Where to save the PPTX file
    ///   - template: Optional template to use
    /// - Returns: URL of the generated PPTX file
    public func generate(
        markdown: String,
        outputPath: URL,
        template: DocumentTemplate? = nil
    ) throws -> URL {
        logger.info("Generating PPTX presentation: \(outputPath.lastPathComponent)")

        // 1. Parse markdown into slides
        let slides = parseMarkdownToSlides(markdown)

        logger.debug("Parsed \(slides.count) slides from markdown")

        // 2. Export any Mermaid diagrams to images
        let exporter = MermaidDiagramExporter()
        var processedSlides: [[String: Any]] = []

        for (index, slide) in slides.enumerated() {
            logger.debug("Processing slide \(index + 1): \(slide.title)")

            var slideData: [String: Any] = ["title": slide.title]

            if let diagramCode = slide.diagramCode {
                // This slide contains a Mermaid diagram
                do {
                    let imagePath = try exporter.exportDiagramToTemp(
                        diagramCode,
                        format: .png,
                        size: CGSize(width: 960, height: 720)
                    )
                    slideData["image"] = imagePath.path
                    logger.debug("Exported Mermaid diagram to: \(imagePath.lastPathComponent)")
                } catch {
                    logger.error("Failed to export Mermaid diagram: \(error.localizedDescription)")
                    // Fallback: treat as code content
                    slideData["content"] = ["[Mermaid Diagram]", diagramCode]
                }
            } else if !slide.content.isEmpty {
                slideData["content"] = slide.content
            }

            processedSlides.append(slideData)
        }

        // 3. Build JSON input for Python script
        var scriptInput: [String: Any] = [
            "slides": processedSlides,
            "output": outputPath.path
        ]

        if let template = template {
            scriptInput["template"] = template.path.path
            logger.debug("Using template: \(template.name)")
        }

        let jsonData = try JSONSerialization.data(
            withJSONObject: scriptInput,
            options: [.prettyPrinted]
        )

        logger.debug("Generated JSON input: \(jsonData.count) bytes")

        // 4. Call Python script via Process
        let result = try executePythonScript(with: jsonData)

        logger.info("PPTX generation complete: \(result.path)")

        return URL(fileURLWithPath: result.path)
    }

    /// Execute Python script with JSON input
    private func executePythonScript(with jsonData: Data) throws -> PPTXResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = [scriptPath]

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        logger.debug("Executing Python script...")

        try process.run()

        // Write JSON to stdin
        inputPipe.fileHandleForWriting.write(jsonData)
        inputPipe.fileHandleForWriting.closeFile()

        // Wait for completion
        process.waitUntilExit()

        // Read output
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

        // Log errors if any
        if !errorData.isEmpty, let errorText = String(data: errorData, encoding: .utf8) {
            logger.warning("Python script stderr: \(errorText)")
        }

        // Check exit code
        guard process.terminationStatus == 0 else {
            let errorMsg = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw PPTXError.scriptFailed(
                code: Int(process.terminationStatus),
                message: errorMsg
            )
        }

        // Parse result
        guard !outputData.isEmpty else {
            throw PPTXError.noOutput
        }

        let result = try JSONDecoder().decode(PPTXResult.self, from: outputData)

        guard result.success else {
            throw PPTXError.generationFailed(result.error ?? "Unknown error")
        }

        return result
    }
}

// MARK: - Markdown Parsing

extension PPTXGenerator {
    /// Represents a slide in the presentation
    private struct Slide {
        let title: String
        let content: [String]
        let diagramCode: String?
    }

    /// Parse markdown into slide structure
    /// - Parameter markdown: The markdown content
    /// - Returns: Array of slides
    private func parseMarkdownToSlides(_ markdown: String) -> [Slide] {
        var slides: [Slide] = []
        var currentTitle = ""
        var currentContent: [String] = []
        var inCodeBlock = false
        var codeBlockLanguage: String?
        var codeBlockContent = ""

        let lines = markdown.components(separatedBy: .newlines)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Detect code block start
            if trimmed.hasPrefix("```") {
                if inCodeBlock {
                    // End of code block
                    inCodeBlock = false

                    // If it's a Mermaid diagram, create a diagram slide
                    if codeBlockLanguage == "mermaid" {
                        if !currentTitle.isEmpty || !currentContent.isEmpty {
                            // Save previous slide first
                            slides.append(Slide(
                                title: currentTitle,
                                content: currentContent,
                                diagramCode: nil
                            ))
                            currentContent = []
                        }

                        // Create diagram slide
                        slides.append(Slide(
                            title: currentTitle.isEmpty ? "Diagram" : currentTitle,
                            content: [],
                            diagramCode: codeBlockContent
                        ))

                        currentTitle = ""  // Reset for next slide
                    }

                    codeBlockLanguage = nil
                    codeBlockContent = ""
                } else {
                    // Start of code block
                    inCodeBlock = true
                    codeBlockLanguage = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces).lowercased()
                    codeBlockContent = ""
                }
                continue
            }

            if inCodeBlock {
                codeBlockContent += line + "\n"
                continue
            }

            // Detect headings (new slides)
            if trimmed.hasPrefix("# ") {
                // Save previous slide if it has content
                if !currentTitle.isEmpty || !currentContent.isEmpty {
                    slides.append(Slide(
                        title: currentTitle,
                        content: currentContent,
                        diagramCode: nil
                    ))
                }

                // Start new slide
                currentTitle = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                currentContent = []
            }
            // Detect bullet points
            else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                let bullet = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                currentContent.append(bullet)
            }
            // Detect numbered lists
            else if let match = trimmed.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
                let bullet = String(trimmed[match.upperBound...]).trimmingCharacters(in: .whitespaces)
                currentContent.append(bullet)
            }
            // Ignore empty lines and other content
        }

        // Save last slide
        if !currentTitle.isEmpty || !currentContent.isEmpty {
            slides.append(Slide(
                title: currentTitle,
                content: currentContent,
                diagramCode: nil
            ))
        }

        return slides
    }
}

// MARK: - Result Types

private struct PPTXResult: Decodable {
    let success: Bool
    let path: String
    let error: String?
}

// MARK: - Error Types

public enum PPTXError: Error, LocalizedError {
    case scriptFailed(code: Int, message: String)
    case generationFailed(String)
    case noOutput

    public var errorDescription: String? {
        switch self {
        case .scriptFailed(let code, let message):
            return "Python script failed (exit code \(code)): \(message)"
        case .generationFailed(let message):
            return "PPTX generation failed: \(message)"
        case .noOutput:
            return "No output from Python script"
        }
    }
}
