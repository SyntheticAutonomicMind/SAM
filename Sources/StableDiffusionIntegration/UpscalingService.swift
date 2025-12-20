// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import CoreGraphics
import Logging

/// Service for upscaling images using RealESRGAN
public class UpscalingService {
    private let logger = Logger(label: "com.sam.upscaling")
    private let pythonPath: String
    private let scriptPath: String

    public enum UpscaleModel: String, Sendable {
        case general = "general"
        case anime = "anime"
        case generalX2 = "general_x2"
    }

    public enum UpscaleError: Error, LocalizedError {
        case pythonScriptNotFound
        case pythonExecutionFailed(String)
        case invalidImage
        case missingPythonEnvironment

        public var errorDescription: String? {
            switch self {
            case .pythonScriptNotFound:
                return "Upscaling script not found"
            case .pythonExecutionFailed(let message):
                return "Upscaling failed: \(message)"
            case .invalidImage:
                return "Invalid image file"
            case .missingPythonEnvironment:
                return "Python environment not configured"
            }
        }
    }

    public init() {
        /// Determine the correct app bundle path
        /// When running from .app bundle, Bundle.main.bundlePath is the .app directory
        /// When running the executable directly (development), we need to find the .app bundle
        let bundlePath: String
        let mainBundlePath = Bundle.main.bundlePath

        if mainBundlePath.hasSuffix(".app") {
            /// Running from .app bundle
            bundlePath = mainBundlePath
        } else {
            /// Running executable directly (development mode)
            /// Look for SAM.app in the same directory as the executable
            let appBundlePath = mainBundlePath + "/SAM.app"
            if FileManager.default.fileExists(atPath: appBundlePath) {
                bundlePath = appBundlePath
            } else {
                /// Fall back to main bundle path
                bundlePath = mainBundlePath
            }
        }

        self.pythonPath = "\(bundlePath)/Contents/Resources/python_env/bin/python3"
        self.scriptPath = "\(bundlePath)/Contents/Resources/scripts/upscale_image.py"

        logger.debug("UpscalingService initialized", metadata: [
            "pythonPath": .string(pythonPath),
            "scriptPath": .string(scriptPath)
        ])
    }

    /// Upscale an image using RealESRGAN
    /// - Parameters:
    ///   - imagePath: Path to input image
    ///   - outputPath: Path to save upscaled image
    ///   - model: Upscaling model to use
    ///   - scale: Upscaling factor (2 or 4)
    ///   - tile: Tile size for memory optimization (0 for no tiling)
    /// - Returns: Path to upscaled image
    public func upscaleImage(
        at imagePath: URL,
        outputPath: URL,
        model: UpscaleModel = .general,
        scale: Int = 4,
        tile: Int = 0
    ) async throws -> URL {
        guard FileManager.default.fileExists(atPath: imagePath.path) else {
            throw UpscaleError.invalidImage
        }

        guard FileManager.default.fileExists(atPath: scriptPath) else {
            logger.error("Upscaling script not found at: \(scriptPath)")
            throw UpscaleError.pythonScriptNotFound
        }

        guard FileManager.default.fileExists(atPath: pythonPath) else {
            logger.error("Python not found at: \(pythonPath)")
            throw UpscaleError.missingPythonEnvironment
        }

        logger.info("Starting image upscaling", metadata: [
            "input": .string(imagePath.path),
            "output": .string(outputPath.path),
            "model": .string(model.rawValue),
            "scale": .stringConvertible(scale),
            "tile": .stringConvertible(tile)
        ])

        /// Build command
        var args = [
            scriptPath,
            "-i", imagePath.path,
            "-o", outputPath.path,
            "-m", model.rawValue,
            "-s", String(scale),
            "--fp32"  // Always use FP32 on CPU (half precision not supported)
        ]

        if tile > 0 {
            args.append(contentsOf: ["--tile", String(tile)])
        }

        /// Execute Python script
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = args

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

            let output = String(data: outputData, encoding: .utf8) ?? ""
            let errorOutput = String(data: errorData, encoding: .utf8) ?? ""

            if process.terminationStatus != 0 {
                logger.error("Upscaling failed", metadata: [
                    "exitCode": .stringConvertible(process.terminationStatus),
                    "stderr": .string(errorOutput)
                ])
                throw UpscaleError.pythonExecutionFailed(errorOutput)
            }

            logger.debug("Upscaling output", metadata: [
                "stdout": .string(output)
            ])

            /// Verify output file exists
            guard FileManager.default.fileExists(atPath: outputPath.path) else {
                throw UpscaleError.pythonExecutionFailed("Output file not created")
            }

            logger.info("Image upscaled successfully", metadata: [
                "outputPath": .string(outputPath.path)
            ])

            return outputPath

        } catch let error as UpscaleError {
            throw error
        } catch {
            logger.error("Failed to execute upscaling script", metadata: [
                "error": .string(error.localizedDescription)
            ])
            throw UpscaleError.pythonExecutionFailed(error.localizedDescription)
        }
    }

    /// Upscale image in-place (overwrites original)
    /// - Parameters:
    ///   - imagePath: Path to image to upscale
    ///   - model: Upscaling model to use
    ///   - scale: Upscaling factor (2 or 4)
    ///   - tile: Tile size for memory optimization (0 for no tiling)
    /// - Returns: Path to upscaled image (same as input)
    public func upscaleImageInPlace(
        at imagePath: URL,
        model: UpscaleModel = .general,
        scale: Int = 4,
        tile: Int = 0
    ) async throws -> URL {
        /// Create temporary output path
        let tempPath = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(imagePath.pathExtension)

        /// Upscale to temp location
        _ = try await upscaleImage(
            at: imagePath,
            outputPath: tempPath,
            model: model,
            scale: scale,
            tile: tile
        )

        /// Replace original with upscaled version
        try FileManager.default.removeItem(at: imagePath)
        try FileManager.default.moveItem(at: tempPath, to: imagePath)

        logger.info("Replaced original image with upscaled version", metadata: [
            "path": .string(imagePath.path)
        ])

        return imagePath
    }
}
