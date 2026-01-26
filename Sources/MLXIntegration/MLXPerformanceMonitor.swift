// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Metal
import Logging

/// Performance monitoring for MLX inference to identify CPU vs GPU bottlenecks.
@MainActor
public class MLXPerformanceMonitor {
    private let logger = Logger(label: "com.sam.mlx.perfmonitor")

    /// Metal device for GPU monitoring.
    private let metalDevice: MTLDevice?

    /// Performance tracking.
    private var startTime: Date?
    private var tokenCount: Int = 0
    private var cpuTimeSeconds: Double = 0
    private var gpuActiveRatio: Double = 0

    public init() {
        self.metalDevice = MTLCreateSystemDefaultDevice()

        if let device = metalDevice {
            logger.debug("Performance monitor initialized with Metal GPU: \(device.name)")
            logger.info("GPU Memory: \(device.recommendedMaxWorkingSetSize / (1024*1024*1024))GB recommended max")
        } else {
            logger.warning("No Metal GPU device found - CPU-only operation detected!")
        }
    }

    /// Begin monitoring a generation session.
    public func beginSession() {
        startTime = Date()
        tokenCount = 0
        cpuTimeSeconds = 0
        gpuActiveRatio = 0

        logger.debug("PERF_SESSION_START: Monitoring CPU/GPU usage")
    }

    /// Record token generation (called for each token).
    public func recordToken() {
        tokenCount += 1
    }

    /// Sample current CPU usage.
    public func sampleCPUUsage() {
        /// Get process CPU usage.
        var usage = rusage()
        if getrusage(RUSAGE_SELF, &usage) == 0 {
            /// User time + System time in seconds.
            let userTime = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
            let systemTime = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
            cpuTimeSeconds = userTime + systemTime
        }
    }

    /// Check if Metal GPU is being utilized.
    public func checkGPUUtilization() -> GPUUtilization {
        guard let device = metalDevice else {
            return GPUUtilization(
                isAvailable: false,
                currentAllocation: UInt64(0),
                recommendedMax: UInt64(0),
                utilizationPercent: 0,
                warning: "No Metal GPU device detected - running on CPU only!"
            )
        }

        /// Get current GPU memory allocation.
        let currentAllocation = UInt64(device.currentAllocatedSize)
        let recommendedMax = UInt64(device.recommendedMaxWorkingSetSize)
        let utilizationPercent = Double(currentAllocation) / Double(recommendedMax) * 100

        /// Check if GPU seems idle (very low memory usage during inference).
        let warning: String?
        let minAllocThreshold: UInt64 = 100 * 1024 * 1024
        if currentAllocation < minAllocThreshold && tokenCount > 10 {
            /// Less than 100MB allocated after 10 tokens - suspicious!.
            let mb = currentAllocation / (1024 * 1024)
            warning = "WARNING: Very low GPU memory usage (\(mb)MB) - model may be running on CPU!"
        } else if utilizationPercent < 5 && tokenCount > 10 {
            warning = "WARNING: GPU utilization extremely low (\(String(format: "%.1f", utilizationPercent))%) - check if model is GPU-accelerated"
        } else {
            warning = nil
        }

        return GPUUtilization(
            isAvailable: true,
            currentAllocation: currentAllocation,
            recommendedMax: recommendedMax,
            utilizationPercent: utilizationPercent,
            warning: warning
        )
    }

    /// End monitoring session and report statistics.
    public func endSession() -> PerformanceReport {
        guard let start = startTime else {
            return PerformanceReport(
                durationSeconds: 0,
                tokenCount: 0,
                tokensPerSecond: 0,
                cpuTimeSeconds: 0,
                cpuUtilizationPercent: 0,
                gpuUtilization: checkGPUUtilization(),
                recommendation: "Session not started"
            )
        }

        let duration = Date().timeIntervalSince(start)
        let tokensPerSecond = Double(tokenCount) / duration

        /// Sample final CPU usage.
        sampleCPUUsage()

        /// CPU utilization as percentage of wall time.
        let cpuUtilizationPercent = (cpuTimeSeconds / duration) * 100

        /// Get GPU stats.
        let gpuUtilization = checkGPUUtilization()

        /// Generate recommendation.
        var recommendation = ""
        if !gpuUtilization.isAvailable {
            recommendation = "CRITICAL: No GPU detected. MLX should only run on Apple Silicon with Metal GPU."
        } else if let warning = gpuUtilization.warning {
            recommendation = warning
        } else if cpuUtilizationPercent > 80 {
            recommendation = "HIGH CPU USAGE: \(String(format: "%.1f", cpuUtilizationPercent))% CPU - check for CPU-bound operations (tokenization, cache management)"
        } else if cpuUtilizationPercent > 50 {
            recommendation = "MODERATE CPU USAGE: \(String(format: "%.1f", cpuUtilizationPercent))% CPU - normal for tokenization/streaming overhead"
        } else {
            recommendation = "OPTIMAL: Low CPU usage (\(String(format: "%.1f", cpuUtilizationPercent))%), GPU handling inference"
        }

        let report = PerformanceReport(
            durationSeconds: duration,
            tokenCount: tokenCount,
            tokensPerSecond: tokensPerSecond,
            cpuTimeSeconds: cpuTimeSeconds,
            cpuUtilizationPercent: cpuUtilizationPercent,
            gpuUtilization: gpuUtilization,
            recommendation: recommendation
        )

        /// Log comprehensive report.
        logger.info("PERF_REPORT: ===== MLX PERFORMANCE ANALYSIS =====")
        logger.info("PERF_REPORT: Duration: \(String(format: "%.2f", duration))s")
        logger.info("PERF_REPORT: Tokens: \(tokenCount) (\(String(format: "%.1f", tokensPerSecond)) tokens/sec)")
        logger.info("PERF_REPORT: CPU Time: \(String(format: "%.2f", cpuTimeSeconds))s (\(String(format: "%.1f", cpuUtilizationPercent))% utilization)")

        if gpuUtilization.isAvailable {
            logger.info("PERF_REPORT: GPU Memory: \(gpuUtilization.currentAllocation / (1024*1024))MB / \(gpuUtilization.recommendedMax / (1024*1024))MB (\(String(format: "%.1f", gpuUtilization.utilizationPercent))%)")
        } else {
            logger.warning("PERF_REPORT: GPU: NOT AVAILABLE")
        }

        logger.info("PERF_REPORT: Recommendation: \(recommendation)")
        logger.info("PERF_REPORT: =====================================")

        return report
    }
}

/// GPU utilization snapshot.
public struct GPUUtilization {
    public let isAvailable: Bool
    public let currentAllocation: UInt64
    public let recommendedMax: UInt64
    public let utilizationPercent: Double
    public let warning: String?
}

/// Complete performance report for an inference session.
public struct PerformanceReport {
    public let durationSeconds: TimeInterval
    public let tokenCount: Int
    public let tokensPerSecond: Double
    public let cpuTimeSeconds: TimeInterval
    public let cpuUtilizationPercent: Double
    public let gpuUtilization: GPUUtilization
    public let recommendation: String
}
