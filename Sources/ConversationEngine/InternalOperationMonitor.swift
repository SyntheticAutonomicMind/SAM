// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import os

/// Internal operation timing monitor for low-level performance tracking
/// Complements the main PerformanceMonitor (in ConfigurationSystem) which tracks API-level metrics
/// This monitor focuses on individual operation timing to identify bottlenecks
public class InternalOperationMonitor {
    public nonisolated(unsafe) static let shared = InternalOperationMonitor()

    private let logger = Logger(subsystem: "com.sam.internal.performance", category: "InternalOperationMonitor")

    // Store timing samples per operation
    private var samples: [String: [TimeInterval]] = [:]
    private let lock = NSLock()

    private init() {}

    /// Record operation duration
    public func record(_ operation: String, duration: TimeInterval) {
        lock.lock()
        samples[operation, default: []].append(duration)
        lock.unlock()

        // Log if slow (>10ms)
        if duration > 0.010 {
            logger.debug("PERF_SLOW: \(operation) took \(String(format: "%.2f", duration * 1000))ms")
        }
    }

    /// Calculate statistics for operation
    public func stats(_ operation: String) -> OperationStats? {
        lock.lock()
        defer { lock.unlock() }

        guard let sorted = samples[operation]?.sorted() else { return nil }
        let count = sorted.count
        guard count > 0 else { return nil }

        let p50 = sorted[Int(Double(count) * 0.50)]
        let p95 = sorted[min(Int(Double(count) * 0.95), count - 1)]
        let p99 = sorted[min(Int(Double(count) * 0.99), count - 1)]
        let max = sorted[count - 1]
        let min = sorted[0]
        let avg = sorted.reduce(0.0, +) / Double(count)

        return OperationStats(
            operation: operation,
            count: count,
            min: min,
            avg: avg,
            p50: p50,
            p95: p95,
            p99: p99,
            max: max
        )
    }

    /// Generate performance report
    public func report() -> String {
        lock.lock()
        let allOperations = samples.keys.sorted()
        lock.unlock()

        var output = "PERFORMANCE REPORT\n"
        output += "==================\n\n"

        for operation in allOperations {
            guard let stats = stats(operation) else { continue }
            output += "\(operation):\n"
            output += "  Count: \(stats.count)\n"
            output += "  Min:   \(String(format: "%.2f", stats.min * 1000))ms\n"
            output += "  Avg:   \(String(format: "%.2f", stats.avg * 1000))ms\n"
            output += "  P50:   \(String(format: "%.2f", stats.p50 * 1000))ms\n"
            output += "  P95:   \(String(format: "%.2f", stats.p95 * 1000))ms\n"
            output += "  P99:   \(String(format: "%.2f", stats.p99 * 1000))ms\n"
            output += "  Max:   \(String(format: "%.2f", stats.max * 1000))ms\n\n"
        }

        return output
    }

    /// Get all operation statistics sorted by P95 descending (slowest first)
    public func allStats() -> [OperationStats] {
        lock.lock()
        let allOperations = samples.keys.sorted()
        lock.unlock()

        var results: [OperationStats] = []
        for operation in allOperations {
            if let stats = stats(operation) {
                results.append(stats)
            }
        }

        return results.sorted { $0.p95 > $1.p95 }
    }

    /// Clear all samples
    public func reset() {
        lock.lock()
        samples.removeAll()
        lock.unlock()
        logger.info("PERF_RESET: All performance samples cleared")
    }

    /// Log performance report to console
    public func logReport() {
        let reportText = report()
        logger.info("PERF_REPORT:\n\(reportText)")
    }
}

/// Statistics for a single operation
public struct OperationStats {
    public let operation: String
    public let count: Int
    public let min: TimeInterval
    public let avg: TimeInterval
    public let p50: TimeInterval
    public let p95: TimeInterval
    public let p99: TimeInterval
    public let max: TimeInterval

    /// Total time spent in this operation
    public var totalTime: TimeInterval {
        return avg * Double(count)
    }
}

/// Convenience function for timing blocks
public func measureInternalOperation<T>(_ operation: String, block: () -> T) -> T {
    let start = CFAbsoluteTimeGetCurrent()
    defer {
        let duration = CFAbsoluteTimeGetCurrent() - start
        InternalOperationMonitor.shared.record(operation, duration: duration)
    }
    return block()
}

/// Convenience function for timing async blocks
public func measureInternalOperationAsync<T>(_ operation: String, block: () async -> T) async -> T {
    let start = CFAbsoluteTimeGetCurrent()
    defer {
        let duration = CFAbsoluteTimeGetCurrent() - start
        InternalOperationMonitor.shared.record(operation, duration: duration)
    }
    return await block()
}
