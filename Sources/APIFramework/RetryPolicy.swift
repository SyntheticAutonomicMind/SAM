// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import Foundation
import Logging

/// Retry policy for API requests with exponential backoff Handles transient network errors, timeouts, and rate limiting.
public struct RetryPolicy: Sendable {

    // MARK: - Configuration

    /// Maximum number of retry attempts (after initial request).
    public let maxRetries: Int

    /// Backoff delays for each retry attempt (in seconds) Example: [2.0, 4.0, 6.0] means retry after 2s, 4s, then 6s.
    public let backoffDelays: [TimeInterval]

    /// HTTP status codes that should trigger retries.
    public let retryableHTTPCodes: Set<Int>

    /// NSURLError codes that should trigger retries.
    public let retryableURLErrorCodes: Set<Int>

    // MARK: - Default Configuration

    /// Default retry policy with 3 retries and 2s/4s/6s backoff.
    /// Rate limit errors use longer delays to respect API limits.
    public nonisolated(unsafe) static let `default` = RetryPolicy(
        maxRetries: 3,
        backoffDelays: [2.0, 4.0, 6.0],
        retryableHTTPCodes: [
            429,
            500,
            502,
            503,
            504
        ],
        retryableURLErrorCodes: [
            -1001,
            -1005,
            -1009
        ]
    )

    /// Rate limit specific retry policy with longer delays
    /// Used for 429 errors to give API time to reset
    public nonisolated(unsafe) static let rateLimitPolicy = RetryPolicy(
        maxRetries: 5,
        backoffDelays: [4.0, 8.0, 16.0, 32.0, 60.0],
        retryableHTTPCodes: [429],
        retryableURLErrorCodes: []
    )

    // MARK: - Lifecycle

    public init(
        maxRetries: Int,
        backoffDelays: [TimeInterval],
        retryableHTTPCodes: Set<Int>,
        retryableURLErrorCodes: Set<Int>
    ) {
        self.maxRetries = maxRetries
        self.backoffDelays = backoffDelays
        self.retryableHTTPCodes = retryableHTTPCodes
        self.retryableURLErrorCodes = retryableURLErrorCodes
    }

    // MARK: - Retry Logic

    /// Determine if an error is retryable.
    public func isRetryable(_ error: Error) -> Bool {
        /// Check for ProviderError rate limit - always retryable
        if case ProviderError.rateLimitExceeded = error {
            return true
        }

        let nsError = error as NSError

        /// Check for retryable NSURLError codes.
        if nsError.domain == NSURLErrorDomain {
            return retryableURLErrorCodes.contains(nsError.code)
        }

        /// Check for HTTP status codes in URLError Note: HTTP response is not directly available in URLError, so we skip this check Retryable errors are determined by URLError code only.

        return false
    }

    /// Get the appropriate backoff delay for rate limit errors
    /// Rate limits need longer waits than regular transient errors
    public func rateLimitBackoffDelay(for attempt: Int) -> TimeInterval? {
        /// Use longer delays for rate limiting: 4s, 8s, 16s, 32s, 60s
        let rateLimitDelays: [TimeInterval] = [4.0, 8.0, 16.0, 32.0, 60.0]
        guard attempt < maxRetries else { return nil }
        guard attempt < rateLimitDelays.count else {
            return rateLimitDelays.last
        }
        return rateLimitDelays[attempt]
    }

    /// Get backoff delay for a specific retry attempt (0-indexed) Returns nil if attempt exceeds maxRetries.
    public func backoffDelay(for attempt: Int) -> TimeInterval? {
        guard attempt < maxRetries else { return nil }
        guard attempt < backoffDelays.count else {
            /// If we run out of configured delays, use the last one.
            return backoffDelays.last
        }
        return backoffDelays[attempt]
    }

    /// Execute a block with retry logic - Parameters: - operation: Async operation to execute - onRetry: Optional callback when retry is attempted - Returns: Result of successful operation - Throws: Last error if all retries exhausted.
    public func execute<T: Sendable>(
        operation: @Sendable @escaping () async throws -> T,
        onRetry: (@Sendable (Int, TimeInterval, Error) -> Void)? = nil
    ) async throws -> T {
        var lastError: Error?
        var isRateLimitError = false

        /// Initial attempt (respects existing rate limiting).
        do {
            return try await operation()
        } catch {
            lastError = error

            /// Check if this is a rate limit error for special handling
            if case ProviderError.rateLimitExceeded = error {
                isRateLimitError = true
            }

            /// If not retryable, throw immediately.
            guard isRetryable(error) else {
                throw error
            }
        }

        /// Retry attempts with backoff.
        /// Rate limit errors get longer backoff delays
        let effectiveMaxRetries = isRateLimitError ? 5 : maxRetries

        for attempt in 0..<effectiveMaxRetries {
            /// Use longer delays for rate limit errors
            let delay: TimeInterval
            if isRateLimitError {
                guard let rateLimitDelay = rateLimitBackoffDelay(for: attempt) else {
                    break
                }
                delay = rateLimitDelay
            } else {
                guard let normalDelay = backoffDelay(for: attempt) else {
                    break
                }
                delay = normalDelay
            }

            /// Notify caller of retry attempt (but don't show rate limit retries to user).
            if !isRateLimitError {
                onRetry?(attempt + 1, delay, lastError!)
            }

            /// Wait before retry.
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

            /// Execute retry.
            do {
                return try await operation()
            } catch {
                lastError = error

                /// Update rate limit status for subsequent retries
                if case ProviderError.rateLimitExceeded = error {
                    isRateLimitError = true
                }

                /// If not retryable, throw immediately.
                guard isRetryable(error) else {
                    throw error
                }
            }
        }

        /// All retries exhausted, throw last error.
        throw lastError!
    }
}

/// Human-readable description of error for UI display.
public func errorDescription(for error: Error) -> String {
    let nsError = error as NSError

    if nsError.domain == NSURLErrorDomain {
        switch nsError.code {
        case -1001: return "Network timeout"
        case -1005: return "Network connection lost"
        case -1009: return "Not connected to internet"
        default: return "Network error (code \(nsError.code))"
        }
    }

    /// For HTTP status codes, check if it's a URLError with status Note: HTTP response details may not always be available.

    return error.localizedDescription
}
