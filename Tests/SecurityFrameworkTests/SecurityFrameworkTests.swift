// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import XCTest
@testable import SecurityFramework

final class SecurityFrameworkTests: XCTestCase {
    func testSecurityManager() {
        let manager = SecurityManager.shared
        /// Use the public API for initialization; ensure it doesn't throw.
        XCTAssertNoThrow(try manager.initializeSecurity())
        XCTAssertTrue(true)
    }
}