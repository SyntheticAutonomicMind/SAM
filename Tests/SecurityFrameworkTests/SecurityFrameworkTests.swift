// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import XCTest
@testable import SecurityFramework

final class SecurityFrameworkTests: XCTestCase {

    // MARK: - KeychainManager Tests

    func testKeychainStoreAndRetrieve() async throws {
        let manager = KeychainManager.shared
        let account = "SecurityFrameworkTests.testKeychainStoreAndRetrieve"
        let secret = "test-secret-value-123"

        // Clean up any existing value
        try? await manager.delete(for: account)

        // Store and retrieve
        try await manager.store(secret: secret, for: account)
        let retrieved = try await manager.retrieve(for: account)
        XCTAssertEqual(retrieved, secret)

        // Clean up
        try? await manager.delete(for: account)
    }

    func testKeychainRetrieveMissingReturnsNil() async throws {
        let manager = KeychainManager.shared
        let account = "SecurityFrameworkTests.testKeychainRetrieveMissingReturnsNil"

        try? await manager.delete(for: account)
        let retrieved = try await manager.retrieve(for: account)
        XCTAssertNil(retrieved)
    }

    func testKeychainUpsert() async throws {
        let manager = KeychainManager.shared
        let account = "SecurityFrameworkTests.testKeychainUpsert"

        try? await manager.delete(for: account)

        try await manager.store(secret: "first", for: account)
        try await manager.store(secret: "second", for: account)

        let retrieved = try await manager.retrieve(for: account)
        XCTAssertEqual(retrieved, "second")

        try? await manager.delete(for: account)
    }

    // MARK: - SecretRedactor Tests

    func testSecretRedactorRedactsEmail() {
        let redactor = SecretRedactor(level: .pii)
        let input = "Contact me at john@example.com for details."
        let output = redactor.redact(input)
        XCTAssertFalse(output.contains("john@example.com"))
        XCTAssertTrue(output.contains("[REDACTED]"))
    }

    func testSecretRedactorRedactsSSN() {
        let redactor = SecretRedactor(level: .pii)
        let input = "SSN: 123-45-6789"
        let output = redactor.redact(input)
        XCTAssertFalse(output.contains("123-45-6789"))
    }

    func testSecretRedactorRedactsCreditCard() {
        let redactor = SecretRedactor(level: .pii)
        let input = "Card: 4111-1111-1111-1111"
        let output = redactor.redact(input)
        XCTAssertFalse(output.contains("4111-1111-1111-1111"))
    }

    func testSecretRedactorRedactsAPIKey() {
        let redactor = SecretRedactor(level: .strict)
        let input = "API key: sk-abcdefABCDEFabcdefABCDEFabcdefABCDEFabcdefABCDEF"
        let output = redactor.redact(input)
        XCTAssertFalse(output.contains("sk-abcdef"))
    }

    func testSecretRedactorRespectsPIILevel() {
        let redactor = SecretRedactor(level: .pii)
        let input = "Email: test@example.com Token: abcdef-ghijkl-mnopqrst"
        let output = redactor.redact(input)
        XCTAssertFalse(output.contains("test@example.com"))
        XCTAssertTrue(output.contains("abcdef-ghijkl-mnopqrst"))
    }

    func testSecretRedactorOff() {
        let redactor = SecretRedactor(level: .off)
        let input = "Email: test@example.com"
        let output = redactor.redact(input)
        XCTAssertEqual(input, output)
    }

    func testSecretRedactorEmptyString() {
        let redactor = SecretRedactor(level: .strict)
        XCTAssertEqual(redactor.redact(""), "")
    }

    func testSecretRedactorCustomRedactionText() {
        let redactor = SecretRedactor(level: .pii, redactionText: "***REDACTED***")
        let input = "Email: test@example.com"
        let output = redactor.redact(input)
        XCTAssertTrue(output.contains("***REDACTED***"))
    }

    // MARK: - InvisibleCharFilter Tests

    func testInvisibleCharFilterDetectsHiddenChars() {
        let text = "Hello\u{200B}World" // Zero-width space
        let result = InvisibleCharFilter.describe(text)
        XCTAssertTrue(result.found)
    }

    func testInvisibleCharFilterCleanText() {
        let text = "Hello World"
        let result = InvisibleCharFilter.describe(text)
        XCTAssertFalse(result.found)
    }

    func testInvisibleCharFilterFilterRemovesHiddenChars() {
        let text = "Hello\u{200B}World"
        let filtered = InvisibleCharFilter.filter(text)
        XCTAssertEqual(filtered, "HelloWorld")
    }

    func testInvisibleCharFilterHasInvisibleChars() {
        XCTAssertTrue(InvisibleCharFilter.hasInvisibleChars("Hello\u{200B}World"))
        XCTAssertFalse(InvisibleCharFilter.hasInvisibleChars("Hello World"))
    }
}
