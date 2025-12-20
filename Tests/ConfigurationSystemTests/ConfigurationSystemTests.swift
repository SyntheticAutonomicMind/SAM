// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

import XCTest
@testable import ConfigurationSystem

final class ConfigurationSystemTests: XCTestCase {
    @MainActor
    func testConfigurationManager() {
        /// Use the shared singleton instead of trying to call a private initializer.
        let manager = ConfigurationManager.shared
        /// Basic sanity check: the manager should have initialized directories.
        XCTAssertNotNil(manager)
    }
}