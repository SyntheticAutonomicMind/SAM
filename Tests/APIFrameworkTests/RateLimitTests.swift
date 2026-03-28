// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import XCTest
@testable import APIFramework

/// Thread-safe counter for use in Sendable closures (Swift 6 concurrency).
private final class AtomicCounter: @unchecked Sendable {
    private var _value = 0
    private let lock = NSLock()

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    @discardableResult
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        _value += 1
        return _value
    }
}

/// Tests for rate limit detection, retry policy, and proactive throttle improvements.
final class RateLimitTests: XCTestCase {

    // MARK: - RetryPolicy Tests

    func testRateLimitPolicyHas15SecondFloor() throws {
        let policy = RetryPolicy.rateLimitPolicy
        let firstDelay = policy.backoffDelays.first
        XCTAssertEqual(firstDelay, 15.0, "Rate limit policy should start with 15s delay")
    }

    func testRateLimitPolicyHas300SecondCap() throws {
        let policy = RetryPolicy.rateLimitPolicy
        let lastDelay = policy.backoffDelays.last
        XCTAssertEqual(lastDelay, 300.0, "Rate limit policy should cap at 300s delay")
    }

    func testRateLimitPolicyMaxRetriesIs20() throws {
        let policy = RetryPolicy.rateLimitPolicy
        XCTAssertEqual(policy.maxRetries, 20, "Rate limit retries should be 20 (effectively unlimited)")
    }

    func testRateLimitPolicyBackoffSequence() throws {
        let policy = RetryPolicy.rateLimitPolicy
        let expected: [TimeInterval] = [15.0, 30.0, 60.0, 120.0, 300.0]
        XCTAssertEqual(policy.backoffDelays, expected, "Rate limit backoff should be 15/30/60/120/300")
    }

    func testRateLimitBackoffDelayReturnsLastForHighAttempts() throws {
        let policy = RetryPolicy.rateLimitPolicy
        // Attempt index beyond backoffDelays array should return last value (300s)
        let delay = policy.rateLimitBackoffDelay(for: 10)
        XCTAssertEqual(delay, 300.0, "Attempts beyond delay array should return cap value")
    }

    func testRateLimitBackoffDelayDoesNotReturnNilForHighAttempts() throws {
        let policy = RetryPolicy.rateLimitPolicy
        // Rate limit delays should never return nil (they always clear)
        let delay = policy.rateLimitBackoffDelay(for: 50)
        XCTAssertNotNil(delay, "Rate limit backoff should never return nil")
    }

    func testDefaultPolicyRetryCountUnchanged() throws {
        let policy = RetryPolicy.default
        XCTAssertEqual(policy.maxRetries, 3, "Default policy should still have 3 retries")
    }

    func testDefaultPolicyDelaysUnchanged() throws {
        let policy = RetryPolicy.default
        let expected: [TimeInterval] = [2.0, 4.0, 6.0]
        XCTAssertEqual(policy.backoffDelays, expected, "Default policy delays should be unchanged")
    }

    // MARK: - Rate Limit Error Detection Tests

    func testProviderErrorRateLimitIsRetryable() throws {
        let policy = RetryPolicy.default
        let error = ProviderError.rateLimitExceeded("test")
        XCTAssertTrue(policy.isRetryable(error), "Rate limit errors must always be retryable")
    }

    func testProviderErrorAuthFailureNotRetryable() throws {
        let policy = RetryPolicy.default
        let error = ProviderError.authenticationFailed("test")
        XCTAssertFalse(policy.isRetryable(error), "Auth failures should not be retryable")
    }

    // MARK: - Rate Limit in 200 Body Detection Tests

    func testRateLimitCodeRegexMatchesUserModelRateLimited() throws {
        let code = "user_model_rate_limited"
        let match = code.range(of: "rate.lim", options: [.regularExpression, .caseInsensitive])
        XCTAssertNotNil(match, "Should detect user_model_rate_limited")
    }

    func testRateLimitCodeRegexMatchesRateLimitExceeded() throws {
        let code = "rate_limit_exceeded"
        let match = code.range(of: "rate.lim", options: [.regularExpression, .caseInsensitive])
        XCTAssertNotNil(match, "Should detect rate_limit_exceeded")
    }

    func testRateLimitCodeRegexMatchesRateLimited() throws {
        let code = "rate_limited"
        let match = code.range(of: "rate.lim", options: [.regularExpression, .caseInsensitive])
        XCTAssertNotNil(match, "Should detect rate_limited")
    }

    func testRateLimitCodeRegexDoesNotMatchUnrelated() throws {
        let code = "invalid_request"
        let match = code.range(of: "rate.lim", options: [.regularExpression, .caseInsensitive])
        XCTAssertNil(match, "Should not match unrelated error codes")
    }

    func testRateLimitCodeRegexIsCaseInsensitive() throws {
        let code = "RATE_LIMITED"
        let match = code.range(of: "rate.lim", options: [.regularExpression, .caseInsensitive])
        XCTAssertNotNil(match, "Should match case-insensitively")
    }

    // MARK: - Exponential Backoff Calculation Tests

    func testExponentialBackoffFirstAttempt() throws {
        let baseDelay: Double = 15.0
        let maxDelay: Double = 300.0
        let retryCount = 1
        let delay = min(maxDelay, baseDelay * pow(2.0, Double(retryCount - 1)))
        XCTAssertEqual(delay, 15.0, "First retry should be 15s")
    }

    func testExponentialBackoffSecondAttempt() throws {
        let baseDelay: Double = 15.0
        let maxDelay: Double = 300.0
        let retryCount = 2
        let delay = min(maxDelay, baseDelay * pow(2.0, Double(retryCount - 1)))
        XCTAssertEqual(delay, 30.0, "Second retry should be 30s")
    }

    func testExponentialBackoffThirdAttempt() throws {
        let baseDelay: Double = 15.0
        let maxDelay: Double = 300.0
        let retryCount = 3
        let delay = min(maxDelay, baseDelay * pow(2.0, Double(retryCount - 1)))
        XCTAssertEqual(delay, 60.0, "Third retry should be 60s")
    }

    func testExponentialBackoffFourthAttempt() throws {
        let baseDelay: Double = 15.0
        let maxDelay: Double = 300.0
        let retryCount = 4
        let delay = min(maxDelay, baseDelay * pow(2.0, Double(retryCount - 1)))
        XCTAssertEqual(delay, 120.0, "Fourth retry should be 120s")
    }

    func testExponentialBackoffFifthAttempt() throws {
        let baseDelay: Double = 15.0
        let maxDelay: Double = 300.0
        let retryCount = 5
        let delay = min(maxDelay, baseDelay * pow(2.0, Double(retryCount - 1)))
        XCTAssertEqual(delay, 240.0, "Fifth retry should be 240s")
    }

    func testExponentialBackoffCapsAt300() throws {
        let baseDelay: Double = 15.0
        let maxDelay: Double = 300.0
        let retryCount = 6
        let delay = min(maxDelay, baseDelay * pow(2.0, Double(retryCount - 1)))
        XCTAssertEqual(delay, 300.0, "Sixth retry should cap at 300s")
    }

    func testExponentialBackoffStaysCapped() throws {
        let baseDelay: Double = 15.0
        let maxDelay: Double = 300.0
        // Even at very high retry counts, should stay at 300
        let retryCount = 100
        let delay = min(maxDelay, baseDelay * pow(2.0, Double(retryCount - 1)))
        XCTAssertEqual(delay, 300.0, "Very high retry counts should still cap at 300s")
    }

    // MARK: - JSON Error Body Parsing Tests

    func testParseRateLimitErrorBody() throws {
        let json: [String: Any] = [
            "error": [
                "code": "user_model_rate_limited",
                "message": "You have been rate limited"
            ]
        ]

        if let errorObj = json["error"] as? [String: Any] {
            let errorCode = errorObj["code"] as? String ?? ""
            let match = errorCode.range(of: "rate.lim", options: [.regularExpression, .caseInsensitive])
            XCTAssertNotNil(match, "Should detect rate limit in error body")
        } else {
            XCTFail("Should parse error object")
        }
    }

    func testParseNonRateLimitErrorBody() throws {
        let json: [String: Any] = [
            "error": [
                "code": "model_not_found",
                "message": "The model does not exist"
            ]
        ]

        if let errorObj = json["error"] as? [String: Any] {
            let errorCode = errorObj["code"] as? String ?? ""
            let match = errorCode.range(of: "rate.lim", options: [.regularExpression, .caseInsensitive])
            XCTAssertNil(match, "Should not detect rate limit for non-rate-limit errors")
        } else {
            XCTFail("Should parse error object")
        }
    }

    func testParseErrorBodyWithNilCode() throws {
        let json: [String: Any] = [
            "error": [
                "message": "Something went wrong"
            ]
        ]

        if let errorObj = json["error"] as? [String: Any] {
            let errorCode = errorObj["code"] as? String ?? ""
            let match = errorCode.range(of: "rate.lim", options: [.regularExpression, .caseInsensitive])
            XCTAssertNil(match, "Should not match when code is nil/missing")
        } else {
            XCTFail("Should parse error object")
        }
    }

    func testNormalResponseHasNoErrorObject() throws {
        let json: [String: Any] = [
            "id": "chatcmpl-123",
            "model": "gpt-4",
            "choices": []
        ]

        let errorObj = json["error"] as? [String: Any]
        XCTAssertNil(errorObj, "Normal responses should have no error object")
    }

    // MARK: - ResponsesErrorEvent Rate Limit Detection Tests

    func testResponsesErrorEventRateLimitDetection() throws {
        let event = ResponsesErrorEvent(code: "user_model_rate_limited", message: "Rate limited", param: nil)
        let errorCode = event.code ?? ""
        let match = errorCode.range(of: "rate.lim", options: [.regularExpression, .caseInsensitive])
        XCTAssertNotNil(match, "Should detect rate limit in Responses API error event")
    }

    func testResponsesErrorEventNonRateLimit() throws {
        let event = ResponsesErrorEvent(code: "server_error", message: "Internal error", param: nil)
        let errorCode = event.code ?? ""
        let match = errorCode.range(of: "rate.lim", options: [.regularExpression, .caseInsensitive])
        XCTAssertNil(match, "Should not detect rate limit for non-rate-limit Responses API errors")
    }

    func testResponsesErrorEventNilCode() throws {
        let event = ResponsesErrorEvent(code: nil, message: "Unknown error", param: nil)
        let errorCode = event.code ?? ""
        let match = errorCode.range(of: "rate.lim", options: [.regularExpression, .caseInsensitive])
        XCTAssertNil(match, "Should not match when Responses API error code is nil")
    }

    // MARK: - RetryPolicy Execute with Rate Limit

    func testRetryPolicyRetriesRateLimitErrors() async throws {
        let counter = AtomicCounter()
        let result: String = try await RetryPolicy.rateLimitPolicy.execute(
            operation: {
                let count = counter.increment()
                if count < 3 {
                    throw ProviderError.rateLimitExceeded("test rate limit")
                }
                return "success"
            }
        )
        XCTAssertEqual(result, "success")
        XCTAssertEqual(counter.value, 3, "Should have retried after rate limit errors")
    }

    func testRetryPolicyDoesNotRetryAuthErrors() async throws {
        let counter = AtomicCounter()
        do {
            let _: String = try await RetryPolicy.default.execute(
                operation: {
                    counter.increment()
                    throw ProviderError.authenticationFailed("test auth failure")
                }
            )
            XCTFail("Should have thrown")
        } catch {
            XCTAssertEqual(counter.value, 1, "Should not retry auth failures")
        }
    }
}
